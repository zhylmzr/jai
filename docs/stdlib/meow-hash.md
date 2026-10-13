# meow_hash

## What it is

A fast 128-bit non-cryptographic hash built from x64 AES decryption rounds. It is bit-exact with Meow hash 0.5 ("calico"), so digests can be exchanged with other implementations. It exists so programs such as the Focus editor, which call `MeowHash` under `#if CPU == .X64`, compile for x64 targets.

## How it works

```jai
#import "meow_hash";

#asm { hash: vec; }
MeowHash(MeowDefaultSeed, xx bytes.count, bytes.data, hash);
low := MeowU64From(hash, 0);
```

`MeowHash` and `MeowU64From` are macros. An `#asm`-declared `vec` register is a 64-byte local of the caller and cannot be passed to a procedure by value, so both take it as a `Code` argument and work on its address (`*(#insert hash)`). The actual work is `meow_hash_bytes(seed, len, source, out)`, an ordinary procedure with the hash state in a `[128] u8` buffer:

1. Eight 16-byte lanes load from the 128-byte seed (`MeowDefaultSeed` is the digits of pi).
2. Each whole 256-byte block of input runs eight mixing stages, each `aesdec`, `paddq` and `pxor` over four overlapping 16-byte loads (offsets 15, 0, 1 and 16 of the stage's 32 bytes).
3. The tail is built in plain Jai into a 128-byte `extra` buffer: the last `len mod 16` bytes zero extended (preceded by a second 16-byte piece when bit 4 of the length is set) give four values, shifted by one byte in each direction; the length gives four more. Two stages fold `extra` in (even when the tail is empty).
4. Up to `(len >> 5) & 7` whole 32-byte pieces of the remainder get one stage each, continuing the register schedule.
5. Twelve shuffle rounds, then four adds, two xors and an add collapse the lanes into 16 bytes.

Registers do not persist between `#asm` blocks (a declared register only means something in its own block), so every block reloads the lanes from the state buffer and stores them back.

## How to change it

The stage bodies are written out in full in `stdlib/meow_hash/module.jai`; the register schedule is `(i, i+4, i+6, i+1, i+2) mod 8` for stage `i` (the whole-block loop uses stages 0..7, the 32-byte pieces stages 2..8). Any change breaks bit-compatibility, which the test vectors will catch.

Gotchas:

- Everything but the constants is under `#if CPU == .X64`; arm64 and wasm callers must keep their own fallback.
- Tail bytes are copied with ordinary loads, so unlike the reference there is no page-boundary trick and no read past the end of `source`.
- The seed parameter is `[128] u8` by value, matching `MeowDefaultSeed`.

## Configuration

None. `MEOW_HASH_VERSION`, `MEOW_HASH_VERSION_NAME` and the page and prefetch constants are informational.

## Dependencies

jaic's `#asm` lowering of `aesdec`, `paddq`, `pxor` and `movdqu` (`sema/asm/simd.rs`); no other module. Test: `tests/stdlib/meow-hash.jai` compares 16 input lengths (0 to 1000) against digests produced by the published 0.5 x64 implementation compiled with clang and run with the default seed; on other CPUs it only prints `ok`. To run the x64 path on an arm64 Mac: `jaic tests/stdlib/meow-hash.jai -target x86_64-apple-darwin -o mh && arch -x86_64 ./mh` (Rosetta).
