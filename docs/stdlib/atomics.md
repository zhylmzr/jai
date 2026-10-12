# Atomics

## What it is

`stdlib/Atomics.jai` has two groups of operations on 1, 2, 4 and 8 byte integers, enums, bools, floats, pointers and procedure pointers:

- The original set (`atomic_read`, `atomic_write`, `atomic_swap`, `atomic_add`, `atomic_and/or/xor`, `atomic_increment/decrement`, `atomic_bit_test_and_set`): always sequentially consistent, built from compare-and-swap loops.
- The ordered set (a jaic extension): `atomic_load`, `atomic_store`, `atomic_exchange`, `atomic_compare_exchange` and `atomic_fetch_add/sub/and/or/xor`, each with a `Memory_Order`. They compile to one hardware atomic instruction (`load atomic`, `store atomic`, `atomicrmw`, `cmpxchg` in LLVM) with the order you name, so a release store or an acquire load costs a plain move on x86-64 and one `ldar`/`stlr` on arm64.

## How it works

```jai
Memory_Order :: enum u8 { RELAXED; ACQUIRE; RELEASE; ACQ_REL; SEQ_CST; }

atomic_load             :: (pointer: *T, $order := .SEQ_CST) -> T
atomic_store            :: (pointer: *T, value: T, $order := .SEQ_CST)
atomic_exchange         :: (pointer: *T, value: T, $order := .SEQ_CST) -> (previous: T)
atomic_compare_exchange :: (pointer: *T, expected: T, desired: T,
                            $success := .SEQ_CST, $failure := .SEQ_CST) -> (exchanged: bool, found: T)
atomic_fetch_add        :: (pointer: *T, operand, $order := .SEQ_CST) -> (previous: T)   // also _sub, _and, _or, _xor
```

The order is a compile-time argument (`$`), so each call site gets exactly the instruction it asks for. The usual rule of the C and Rust memory models applies:

| Order | Allowed on | Meaning |
|---|---|---|
| `RELAXED` | everything | The access is atomic and nothing else. |
| `ACQUIRE` | load, read-modify-write, a compare-exchange's failure | Later accesses of this thread cannot move before it; it sees everything written before the `RELEASE` that stored the value it reads. |
| `RELEASE` | store, read-modify-write, a compare-exchange's success | Earlier accesses cannot move after it; they are visible to an `ACQUIRE` of the value. |
| `ACQ_REL` | read-modify-write | Both. |
| `SEQ_CST` | everything | `ACQ_REL`, plus one total order of all `SEQ_CST` operations. The default. |

A load cannot be `RELEASE` or `ACQ_REL`, a store cannot be `ACQUIRE` or `ACQ_REL`, and the failure order of a compare-exchange cannot be `RELEASE` or `ACQ_REL`: these are compile errors (`#assert`), not silent upgrades.

Publishing data from one thread to another is the pair to reach for:

```jai
// producer                                      // consumer
payload = compute();                             while atomic_load(*ready, .ACQUIRE) == 0 {}
atomic_store(*ready, 1, .RELEASE);               use(payload);
```

Notes:

- `atomic_compare_exchange` compares bit for bit. It returns whether it stored, and the value it found (the new value is not returned). It is the strong form: it does not fail spuriously.
- The fetch operations take integers. `atomic_fetch_add` and `atomic_fetch_sub` also take a pointer, with a byte count (`atomic_fetch_add(*cursor, 8)` moves it 8 bytes, not 8 elements). Operands are truncated to the width of the target, like `atomic_add`.
- The exchange family works on `float` and pointer types by operating on their bits.
- Atomic access needs natural alignment. Struct fields and array elements of these types have it; a field of a `#no_padding` or packed layout may not.

## How to change it

The ordered procedures are thin wrappers over nine compiler intrinsics, declared at the bottom of `Atomics.jai` (`atomic_load_order`, `atomic_store_order`, `atomic_exchange_order`, `atomic_fetch_{add,sub,and,or,xor}_order`, `atomic_compare_exchange_order`). The last argument of each is the order as a compile-time constant (a compare-exchange packs `success | failure << 4`). `emit_intrinsic` in `sema/calls.rs` turns them into `ir::Intrinsic::AtomicLoad/AtomicStore/AtomicRmw/AtomicCas` with the orders as payload, and validates the combinations; see [intrinsics](../language/intrinsics.md). Two backends implement the IR ops:

- `crates/jaic-llvm/src/lower.rs`: native code and wasm, one LLVM instruction each. Floats and pointers go through the integer of their width, and the alignment of an atomic access is stated explicitly (LLVM requires it).
- `crates/jaic/src/interp/mod.rs`: the interpreter runs one thread at a time, so every order behaves as `SEQ_CST`. A load, or a read-modify-write that changes nothing, counts as a poll for the cooperative thread scheduler, the way a failed compare-and-swap does, so spin loops on `atomic_load` let other threads run ([interpreter threads](../compiler/interpreter-threads.md)).

To add an operation (a `fetch_nand`, a `min`), add an `AtomicOp`, map the intrinsic name in `emit_intrinsic`, and handle it in both backends. Tests: `tests/stdlib/atomics-ordered.jai` (every width, order, type, plus a release/acquire hand-off and a lock between threads) and `ordered_atomics_keep_their_memory_orders` in `crates/jaic-cli/tests/native.rs` (the LLVM IR carries the requested orders).

## Configuration

None. The older `compare_and_swap2` (a 16-byte compare-and-swap) is deprecated and works only on Linux x64 through the system `libatomic`.

## Dependencies

The compiler's atomic intrinsics only. `Basic` is imported for the `assert` the older procedures use.
