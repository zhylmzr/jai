// Authored scalar operations share the checked compare_and_swap primitive.
atomic_read :: (pointer: *$T) -> T #expand {
    zero: T;
    _, observed := compare_and_swap(pointer, zero, zero);
    return observed;
}

atomic_swap :: (dest: *$T, new_value: T) -> (old_value: T) {
    old := atomic_read(dest);

    while true {
        success, observed := compare_and_swap(dest, old, new_value);
        if success return old;
        old = observed;
    }
}

atomic_write :: (pointer: *$T, new_value: T) #expand {
    atomic_swap(pointer, new_value);
}

atomic_add :: (dest: *$T, to_add: $I) -> T {
    old := atomic_read(dest);

    while true {
        replacement := old + cast,trunc(T) to_add;
        success, observed := compare_and_swap(dest, old, replacement);
        if success return old;
        old = observed;
    }

    return old;
}

atomic_increment :: (dest: *$T) {
    atomic_add(dest, 1);
}

atomic_decrement :: (dest: *$T) -> bool {
    old := atomic_add(dest, -1);
    return old == 1;
}

atomic_and :: (dest: *$T, value: T) {
    old := atomic_read(dest);

    while true {
        success, observed := compare_and_swap(dest, old, old & value);
        if success return;
        old = observed;
    }
}

atomic_or :: (dest: *$T, value: T) {
    old := atomic_read(dest);

    while true {
        success, observed := compare_and_swap(dest, old, old | value);
        if success return;
        old = observed;
    }
}

atomic_xor :: (dest: *$T, value: $I) {
    old := atomic_read(dest);

    while true {
        success, observed := compare_and_swap(dest, old, old ^ cast,trunc(T) value);
        if success return;
        old = observed;
    }
}

atomic_bit_test_and_set :: (dest: *$T, $$i: s64) -> bool {
    assert(i >= 0 && i < size_of(T) * 8);
    mask := (cast(T) 1) << i;
    old := atomic_read(dest);

    while true {
        success, observed := compare_and_swap(dest, old, old | mask);
        if success return (old & mask) != 0;
        old = observed;
    }

    return false;
}

// Ordered operations. A jaic extension: every call states how much ordering it needs, and the
// default is the strongest, so an unmarked call behaves like the unordered procedures above.
// See docs/stdlib/atomics.md.
Memory_Order :: enum u8 {
    RELAXED :: 0; // atomic, but orders nothing around it
    ACQUIRE :: 1; // a load: later accesses stay after it, and see what a RELEASE of the value published
    RELEASE :: 2; // a store: earlier accesses stay before it, and become visible to an ACQUIRE of the value
    ACQ_REL :: 3; // both, for a read-modify-write
    SEQ_CST :: 4; // ACQ_REL, plus one total order of every SEQ_CST operation
}

atomic_load :: (pointer: *$T, $order := Memory_Order.SEQ_CST) -> T {
    #assert IsAtomicScalar(T) "atomic_load takes a 1, 2, 4 or 8 byte integer, enum, bool, float, pointer or procedure";
    #assert order != Memory_Order.RELEASE && order != Memory_Order.ACQ_REL "a load can be RELAXED, ACQUIRE or SEQ_CST";

    return atomic_load_order(pointer, cast(s64) order);
}

atomic_store :: (pointer: *$T, value: T, $order := Memory_Order.SEQ_CST) {
    #assert IsAtomicScalar(T) "atomic_store takes a 1, 2, 4 or 8 byte integer, enum, bool, float, pointer or procedure";
    #assert order != Memory_Order.ACQUIRE && order != Memory_Order.ACQ_REL "a store can be RELAXED, RELEASE or SEQ_CST";

    atomic_store_order(pointer, value, cast(s64) order);
}

// Stores `value` and returns what was there.
atomic_exchange :: (pointer: *$T, value: T, $order := Memory_Order.SEQ_CST) -> (previous: T) {
    #assert IsAtomicScalar(T) "atomic_exchange takes a 1, 2, 4 or 8 byte integer, enum, bool, float, pointer or procedure";

    return atomic_exchange_order(pointer, value, cast(s64) order);
}

// Stores `desired` when the value equals `expected` (bit for bit). Returns whether it did, and the
// value it found. `success` orders the exchange when it happens, `failure` the load when it does not
// (RELAXED, ACQUIRE or SEQ_CST).
atomic_compare_exchange :: (pointer: *$T, expected: T, desired: T,
    $success := Memory_Order.SEQ_CST, $failure := Memory_Order.SEQ_CST) -> (exchanged: bool, found: T) {
    #assert IsAtomicScalar(T) "atomic_compare_exchange takes a 1, 2, 4 or 8 byte integer, enum, bool, float, pointer or procedure";
    #assert failure != Memory_Order.RELEASE && failure != Memory_Order.ACQ_REL "the failure order of a compare-exchange can be RELAXED, ACQUIRE or SEQ_CST";

    ok, found := atomic_compare_exchange_order(pointer, expected, desired, (cast(s64) success) | ((cast(s64) failure) << 4));

    return ok, found;
}

// The fetch operations update the value and return what it was before. They take integers; a
// pointer takes atomic_fetch_add and atomic_fetch_sub with a byte count.
atomic_fetch_add :: (pointer: *$T, operand: $O, $order := Memory_Order.SEQ_CST) -> (previous: T) {
    #if IsPointer(T) {
        return cast(T) atomic_fetch_add_order(cast(*u64) pointer, cast,trunc(u64) operand, cast(s64) order);
    } else {
        #assert IsInteger(T) "atomic_fetch_add takes an integer or a pointer";

        return atomic_fetch_add_order(pointer, cast,trunc(T) operand, cast(s64) order);
    }
}

atomic_fetch_sub :: (pointer: *$T, operand: $O, $order := Memory_Order.SEQ_CST) -> (previous: T) {
    #if IsPointer(T) {
        return cast(T) atomic_fetch_sub_order(cast(*u64) pointer, cast,trunc(u64) operand, cast(s64) order);
    } else {
        #assert IsInteger(T) "atomic_fetch_sub takes an integer or a pointer";

        return atomic_fetch_sub_order(pointer, cast,trunc(T) operand, cast(s64) order);
    }
}

atomic_fetch_and :: (pointer: *$T, operand: $O, $order := Memory_Order.SEQ_CST) -> (previous: T) {
    #assert IsInteger(T) "atomic_fetch_and takes an integer";

    return atomic_fetch_and_order(pointer, cast,trunc(T) operand, cast(s64) order);
}

atomic_fetch_or :: (pointer: *$T, operand: $O, $order := Memory_Order.SEQ_CST) -> (previous: T) {
    #assert IsInteger(T) "atomic_fetch_or takes an integer";

    return atomic_fetch_or_order(pointer, cast,trunc(T) operand, cast(s64) order);
}

atomic_fetch_xor :: (pointer: *$T, operand: $O, $order := Memory_Order.SEQ_CST) -> (previous: T) {
    #assert IsInteger(T) "atomic_fetch_xor takes an integer";

    return atomic_fetch_xor_order(pointer, cast,trunc(T) operand, cast(s64) order);
}

IsAtomicScalar :: (T: Type) -> bool #compile_time {
    bytes := type_info(T).runtime_size;
    if bytes != 1 && bytes != 2 && bytes != 4 && bytes != 8 return false;

    info := type_info(T);
    while info.type == .VARIANT info = (cast(*Type_Info_Variant) info).variant_of;

    return info.type == .INTEGER || info.type == .ENUM || info.type == .BOOL ||
           info.type == .FLOAT || info.type == .POINTER || info.type == .PROCEDURE;
}

compare_and_swap2 :: (dest: *void, old_value_1: $T1_64, old_value_2: $T2_64,
    new_value_1: T1_64, new_value_2: T2_64) -> bool
    #deprecated "Nobody is using this and it is currently x64-only so... yeah." {
    #assert size_of(T1_64) == 8 && size_of(T2_64) == 8;

    #if OS == .LINUX && CPU == .X64 {
        pair: [2] u64;
        replacement: [2] u64;

        memcpy(*pair, *old_value_1, 8);
        memcpy(*pair[1], *old_value_2, 8);
        memcpy(*replacement, *new_value_1, 8);
        memcpy(*replacement[1], *new_value_2, 8);

        return native_compare_exchange(16, dest, *pair, *replacement, 5, 5);
    } else {
        assert(false, "compare_and_swap2 requires the Linux system libatomic provider");
        return false;
    }
}

#scope_file
#import "Basic";

// The compiler operations behind the ordered procedures. The last argument is a compile-time
// memory order (`Memory_Order`); a compare-exchange packs success | failure << 4.
atomic_load_order :: (pointer: *$T, order: s64) -> T #intrinsic;
atomic_store_order :: (pointer: *$T, value: T, order: s64) #intrinsic;
atomic_exchange_order :: (pointer: *$T, value: T, order: s64) -> T #intrinsic;
atomic_fetch_add_order :: (pointer: *$T, value: T, order: s64) -> T #intrinsic;
atomic_fetch_sub_order :: (pointer: *$T, value: T, order: s64) -> T #intrinsic;
atomic_fetch_and_order :: (pointer: *$T, value: T, order: s64) -> T #intrinsic;
atomic_fetch_or_order :: (pointer: *$T, value: T, order: s64) -> T #intrinsic;
atomic_fetch_xor_order :: (pointer: *$T, value: T, order: s64) -> T #intrinsic;
atomic_compare_exchange_order :: (pointer: *$T, old: T, new: T, order: s64) -> (bool, T) #intrinsic;

IsInteger :: (T: Type) -> bool #compile_time {
    info := type_info(T);
    while info.type == .VARIANT info = (cast(*Type_Info_Variant) info).variant_of;

    return info.type == .INTEGER;
}

IsPointer :: (T: Type) -> bool #compile_time {
    info := type_info(T);
    while info.type == .VARIANT info = (cast(*Type_Info_Variant) info).variant_of;

    return info.type == .POINTER;
}

#if OS == .LINUX && CPU == .X64 {
    atomic_library :: #system_library "atomic";

    native_compare_exchange :: (size: u64, dest: *void, expected: *void,
        replacement: *void, success_order: s32, failure_order: s32) -> bool
        #foreign atomic_library "__atomic_compare_exchange";
}

integer_for_size :: (size: s64, signed := false) -> Type, exists: bool = true #compile_time {
    if signed {
        if size == 1 return s8, true;
        if size == 2 return s16, true;
        if size == 4 return s32, true;
        if size == 8 return s64, true;
    } else {
        if size == 1 return u8, true;
        if size == 2 return u16, true;
        if size == 4 return u32, true;
        if size == 8 return u64, true;
    }

    return void, false;
}

IsSigned :: (type: Type) -> bool #compile_time {
    info := type_info(type);
    while info.type == .VARIANT info = (cast(*Type_Info_Variant) info).variant_of;
    if info.type == .ENUM info = (cast(*Type_Info_Enum) info).internal_type;
    if info.type != .INTEGER return false;

    return (cast(*Type_Info_Integer) info).signed;
}
