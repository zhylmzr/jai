# Json: typed JSON generated at compile time (jaic extension)

## What it is

`#import "Extensions/Json";` gives `to_json`, `from_json` and `parse_json`, modelled on Rust's `serde_json`. Encoders and decoders for your own types are generated at compile time from `Type_Info` (`#insert` inside polymorphic procedures, the same technique as `Extensions/Regex` and `Extensions/Args`). A jaic extension, not official Jai.

```jai
User :: struct @json(rename_all=camelCase) {
    id: int;
    display_name: string;                       // "displayName"
    email: string;  @json(skip_serializing_if=empty,default)
    tags: [..] string;
}

text := to_json(user);                          // to_json(user, pretty = true) indents
user, error := from_json(User, text);           // error.kind == .NONE on success
if error.kind != .NONE print("%\n", json_error_text(error));
value, error := parse_json(text);               // a Json_Value tree when the shape is unknown
```

## API

| Procedure | Purpose |
| --- | --- |
| `to_json(value, pretty := false) -> string` | encode any supported value; caller frees the string |
| `write_json(*builder, value, pretty := false)` | encode into a `String_Builder` |
| `from_json($T, text, options := .{}) -> T, Json_Error` | decode into `T`; the error has `kind`, `message`, `offset`, `line`, `column`, `path` (`tags[2]`) |
| `parse_json(text, options) -> Json_Value, Json_Error` | untyped tree |
| `json_null/bool/int/uint/float/string/array/object`, `json_push`, `json_set` | build a `Json_Value` |
| `json_get`, `json_at`, `json_count`, `json_as_bool`, `json_as_string`, `json_free` | read one |
| `json_error_text`, `free_json_error` | format and release errors |

`Json_Options` has `max_depth` (256) and `max_size` (1 GiB); exceeding either is a `.LIMIT` error.

## Types

Integers are exact over their full range (including 64-bit); a number that does not fit is `.OUT_OF_RANGE`. Floats print as the shortest string that round-trips (`0.1`, `1e21`; integral values get `.0`); `NaN` and infinities encode as `null`. Decoding floats is correctly rounded: after the RFC 8259 grammar check, the token goes to Basic's conversion (`scan_decimal_float` and `decimal_float_to_float64`/`32`, see `Float_Parse.jai`), with no exponent limit, so `1e999999` is `.OUT_OF_RANGE` and `1e-999999` is zero. Supported: strings, bools, enums (by name, or number with `as_number`), fixed/view/resizable arrays, pointers (`null` or a value), nested and recursive structs, `Hash_Table` with string keys, and `Json_Value`. 128-bit integers are not.

## Attributes

Written as a note after the member's `;`, options comma-separated: `@json(rename=x,alias=y)`. Struct-level notes go before `{`.

| Option | Where | Effect |
| --- | --- | --- |
| `rename=x`, `alias=y` | member | JSON key; extra accepted key on decode |
| `rename_all=RULE` | struct | lowercase, UPPERCASE, camelCase, PascalCase, snake_case, SCREAMING_SNAKE_CASE, kebab-case, SCREAMING-KEBAB-CASE |
| `skip`, `skip_serializing`, `skip_deserializing` | member | omit in one or both directions |
| `skip_serializing_if=empty\|zero\|null` | member | omit when empty string/array/table, zero, or null pointer/`Json_Value` |
| `default` | member or struct | a missing field keeps its initializer instead of being an error |
| `flatten` | member | inline a struct member's fields; key clashes are compile errors |
| `with=name` | member | calls `T.name_encode(w, *field)` / `T.name_decode(r, *field)` declared inside the struct |
| `as_number` | enum member | encode as the enum's number |
| `deny_unknown_fields`, `transparent` | struct | unknown keys are errors; a one-field struct encodes as that field |

Deviation from the plan: `with=` names procedures declared inside the struct, not file-scope ones, because generated code cannot see user-scope identifiers.

Unknown fields are ignored unless denied; a missing field with no `default` is an error naming it; duplicate keys are an error. Attribute mistakes are compile errors reported through `compiler_report`.

## Parsing rules

Strict RFC 8259: no BOM, trailing commas, leading zeros, lone surrogates, invalid UTF-8 or raw control characters in strings. Line and column count characters. Encoding replaces invalid UTF-8 with U+FFFD. A failed decode can leak partial allocations of the half-built value; decode untrusted input under an arena or `push_allocator`.

### JSONTestSuite

`tests/data/JSONTestSuite/` vendors `test_parsing` (MIT, LICENSE alongside; `.gitattributes` keeps it byte-exact). Results: all 95 `y_` accepted, all 188 `n_` rejected, and the 35 `i_` cases do not crash: 10 are accepted and 25 rejected. The per-case choice is recorded in `tests/suite.jai`; the rule is that anything outside RFC 8259 grammar, any invalid UTF-8 or invalid surrogate use, and nesting beyond the limit are rejected, while grammatical documents (large numbers, which become floats or range errors when typed) are accepted. `tools/gen_json_corpus.py` regenerates `tests/data/suite_cases.jai` from the files.

## What is specialized at compile time

- Per-type encoder and decoder bodies: straight-line code per struct, no runtime type switch. Each field's decoder is the code for that field's type, and a value of the wrong kind produces an error carrying the path.
- Key matching: for each field and alias the generator emits a length test followed by comparisons of 8/4/2/1-byte words against constants built at compile time (little-endian targets). No string table walk, no hashing. Keys with escapes are unescaped by the reader before matching.
- Key emission: compact output appends one prebuilt `"key":` or `,"key":` constant per field (pretty output goes through the indent-aware path).
- Rename rules, aliases, defaults, skip conditions and the size of the `seen` array are resolved at compile time.
- Constant documents can be decoded at compile time with `#run` and baked in (see `tests/baked.jai`):

```jai
make :: () -> Config { config, error := from_json(Config, "{\"port\":80}"); return config; }
config :: #run make();
```

## SIMD

Vector code (via `Extensions/SIMD`, `u8x16`: SSE2/NEON) accelerates the hot byte scans. Scalar code is the reference, and is used on wasm and wherever vectors are unavailable.

- Encoder: finds bytes that need escaping 16 at a time (with a scalar budget after high bytes, so UTF-8-heavy text does not regress).
- Parser: string bodies are scanned 16 bytes at a time for quote, backslash, control and non-ASCII bytes.
- Stage 1 index (`index.jai`): for texts of at least `json_index_min_size` (256) bytes, 64-byte blocks produce bit masks of quotes, backslashes, control and high bytes; simdjson's odd-backslash-run trick finds escaped quotes, a prefix XOR of the quote bits marks string interiors, and UTF-8 is validated at the high bytes in the same pass. The index lists string extents, so long strings are taken in one step. It is gated: if the first 32 KB has more than one entry per 48 bytes or fewer than one per 2 KB it is abandoned, because short strings and number arrays do not repay it. Any anomaly (or any later failure) makes the decoder re-parse with the scalar reader, so errors, positions and paths are identical on every path by construction.
- `json_use_simd = false` forces the scalar paths. `tests/differential.jai` compares both on thousands of generated and boundary texts; the whole suite, JSONTestSuite included, runs in interp, native, wasm-interp and wasm-native (SIMD is off on wasm, so those modes exercise scalar).

### Not done, and why

A full simdjson-style structural index (every `{}[],:` plus a stage 2 that walks it) was built experimentally and dropped: for documents of short strings and numbers it cost more to build than the scalar reader's own byte checks cost to repeat. `from_json(T)` is already a schema-guided single pass (generated decoder over the bytes, vector string scanning, no full index), and it measured equal to or faster than index-then-decode, so typed decoding does not build a structural index. A structural index or tape for `parse_json`, and simd-json-style number fast paths, remain possible future steps.

### Benchmark

`stdlib/Extensions/Json/bench/bench.jai` (build with `-O2`); `tools/json_bench_data.py` downloads twitter.json, canada.json and citm_catalog.json, which are not vendored. Apple silicon, native `-O2`, MB/s, best of two. "vector" is the vector scans; "+ index" adds stage 1 (forced for every size).

| Document | Operation | scalar | vector | + index |
| --- | --- | --- | --- | --- |
| twitter.json (632 KB) | parse_json | 571 | 627 | 623 |
| twitter.json | to_json (Json_Value) | 730 | 814 | 813 |
| canada.json (2.2 MB) | parse_json | 419 | 422 | 403 |
| canada.json | to_json (Json_Value) | 1207 | 1300 | 1194 |
| citm_catalog.json (1.7 MB) | parse_json | 755 | 773 | 772 |
| citm_catalog.json | to_json (Json_Value) | 590 | 580 | 583 |
| long strings (5.7 MB) | parse_json | 1039 | 1080 | 1422 |
| generated catalog (4 MB) | from_json(Catalog) | 440 | 457 | 458 |
| generated catalog | to_json(Catalog) | 503 | 529 | 524 |

Gains are modest (about 1.0 to 1.1x, 1.4x for long clean strings): the parser is mostly bound by value construction and number conversion, not byte scanning.

## How to change it

- New attribute: parse it in `collect_leaves` (`generate.jai`), carry it on `Leaf`, and emit it in `generate_encoder` / `generate_decoder`.
- New type: add cases to `emit_encode` and `emit_decode`.
- Runtime helpers (`json_read_*`, `json_key`, ...) live in `reader.jai` and `writer.jai`; float printing in `number.jai` (reading a validated token calls Basic); stage 1 in `index.jai`.
- Vector paths stay behind `simd_enabled()` and must give identical results; run `tests/differential.jai`.

## Configuration

`json_use_simd` (default true), `json_index_min_size` (256), `Json_Options.max_depth` / `max_size`, and `json_index_stats` (counters).

## Dependencies

`Basic`, `String`, `Compiler`, `Hash_Table`, `Extensions/SIMD`.

## Credits

The structural-index design follows simdjson (Langdale and Lemire, "Parsing Gigabytes of JSON per Second") and its Rust port simd-json, both used as design references. The code here is written for this repo.
