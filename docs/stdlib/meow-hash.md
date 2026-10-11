# meow_hash

## What it is

A fast 128-bit non-cryptographic hash built from x64 AES decryption rounds, in the style of Meow hash 0.5. It exists so programs such as the Focus editor, which call `MeowHash` under `#if CPU == .X64`, compile for x64 targets.

## How it works

```jai
#import "meow_hash";

#asm { hash: vec; }
MeowHash(MeowDefaultSeed, xx bytes.count, bytes.data, hash);
low := MeowU64From(hash, 0);
```

`MeowHash` and `MeowU64From` are macros. An `#asm`-declared `vec` register is a 64-byte local of the caller and cannot be passed to a procedure by value, so both take it as a `Code` argument and work on its address (`*(#insert hash)`). The actual work is `meow_hash_bytes(seed, len, source, out)`, an ordinary procedure with the hash state in a `[128] u8` buffer:

1. Eight 16-byte lanes load from the 128-byte seed (`MeowDefaultSeed` is the digits of pi).
2. Each 256-byte block of input runs eight mixing stages, each `aesdec`, `paddq` and `pxor` over four overlapping 16-byte loads (offsets 15, 0, 1 and 16 of the stage's 32 bytes).
3. A trailing partial block is zero padded to 256 bytes and mixed the same way.
4. The byte count (and its complement) is folded in, twelve shuffle rounds run, and four adds, two xors and an add collapse the lanes into 16 bytes.

Registers do not persist between `#asm` blocks (a declared register only means something in its own block), so every block reloads the lanes from the state buffer and stores them back.

## How to change it

The stage bodies are written out in full in `stdlib/meow_hash/module.jai`; the register schedule is `(i, i+4, i+6, i+1, i+2) mod 8` for stage `i`. Change it in the three places the block text appears (full block, tail block, and the `meow_hash_bytes` finish) together, and mirror it in the software model in `tests/stdlib/meow-hash.jai`.

Gotchas:

- Everything but the constants is under `#if CPU == .X64`; arm64 and wasm callers must keep their own fallback.
- The digest is stable but is not claimed to equal the digests of other Meow implementations (the tail handling and length folding are this module's own). Do not persist or exchange it.
- The seed parameter is `[128] u8` by value, matching `MeowDefaultSeed`.

## Configuration

None. `MEOW_HASH_VERSION`, `MEOW_HASH_VERSION_NAME` and the page and prefetch constants are informational.

## Dependencies

jaic's `#asm` lowering of `aesdec`, `paddq`, `pxor` and `movdqu` (`sema/asm/simd.rs`); no other module. Test: `tests/stdlib/meow-hash.jai` compares 15 input lengths against a software AES model written in the test (run it with `jaic run -cpu x64`; on other CPUs it only prints `ok`).
