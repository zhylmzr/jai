// Correctly rounded decimal-to-binary conversion behind string_to_float64 and string_to_float
// (and Extensions/Json): the nearest value, ties to even, subnormals and overflow included, for
// float64 and float32 alike.
//
// Most numbers take a fast path (a mantissa below 2^53, or 2^24 for float32, and a small power of
// ten, where one IEEE operation is exact); the rest go through big-integer division, which costs
// a few hundred operations for a 17-digit number and does not depend on any libc. Up to 800
// digits are kept exactly and any digit past that only marks the value as "slightly more", which
// is enough to break a tie correctly (a halfway case needs at most 767 digits).

#scope_file

BIG_LIMBS :: 160; // 5120 bits: 800 digits times 10^323 fits with room for the shifts

Big :: struct {
    limbs: [BIG_LIMBS] u32;
    n: s64; // limbs in use; the top one is never zero
}

big_set_small :: (b: *Big, value: u32) {
    b.n = 0;

    if value {
        b.limbs[0] = value;
        b.n = 1;
    }
}

big_mul_small :: (b: *Big, m: u32) {
    carry: u64;

    for 0..b.n - 1 {
        product := cast(u64) b.limbs[it] * cast(u64) m + carry;
        b.limbs[it] = cast,no_check(u32) product;
        carry = product >> 32;
    }

    if carry {
        b.limbs[b.n] = cast,no_check(u32) carry;
        b.n += 1;
    }
}

big_add_small :: (b: *Big, a: u32) {
    carry := cast(u64) a;
    i := 0;

    while carry && i < b.n {
        sum := cast(u64) b.limbs[i] + carry;
        b.limbs[i] = cast,no_check(u32) sum;
        carry = sum >> 32;
        i += 1;
    }

    if carry {
        b.limbs[b.n] = cast,no_check(u32) carry;
        b.n += 1;
    }
}

big_shift_left :: (b: *Big, bits: s64) {
    if b.n == 0 || bits == 0 return;

    words := bits / 32;
    rest := cast(u32) (bits % 32);

    if rest {
        carry: u32;

        for 0..b.n - 1 {
            value := b.limbs[it];
            b.limbs[it] = (value << rest) | carry;
            carry = value >> (32 - rest);
        }

        if carry {
            b.limbs[b.n] = carry;
            b.n += 1;
        }
    }

    if words {
        i := b.n - 1;

        while i >= 0 {
            b.limbs[i + words] = b.limbs[i];
            i -= 1;
        }

        for 0..words - 1 b.limbs[it] = 0;

        b.n += words;
    }
}

big_shift_right_one :: (b: *Big) {
    carry: u32;
    i := b.n - 1;

    while i >= 0 {
        value := b.limbs[i];
        b.limbs[i] = (value >> 1) | carry;
        carry = value << 31;
        i -= 1;
    }

    if b.n && b.limbs[b.n - 1] == 0 b.n -= 1;
}

big_cmp :: (a: *Big, b: *Big) -> s64 {
    if a.n != b.n return ifx a.n < b.n then -1 else 1;

    i := a.n - 1;

    while i >= 0 {
        if a.limbs[i] != b.limbs[i] return ifx a.limbs[i] < b.limbs[i] then -1 else 1;

        i -= 1;
    }

    return 0;
}

// a -= b, where a >= b.
big_sub :: (a: *Big, b: *Big) {
    borrow: u64;

    for 0..a.n - 1 {
        subtrahend := borrow;
        if it < b.n subtrahend += b.limbs[it];

        value := cast(u64) a.limbs[it];

        if value >= subtrahend {
            a.limbs[it] = cast,no_check(u32) (value - subtrahend);
            borrow = 0;
        } else {
            a.limbs[it] = cast,no_check(u32) (value + 0x1_0000_0000 - subtrahend);
            borrow = 1;
        }
    }

    while a.n && a.limbs[a.n - 1] == 0 a.n -= 1;
}

big_bit_length :: (b: *Big) -> s64 {
    if b.n == 0 return 0;

    top := b.limbs[b.n - 1];
    bits := 0;

    while top {
        bits += 1;
        top >>= 1;
    }

    return (b.n - 1) * 32 + bits;
}

big_mul_pow10 :: (b: *Big, exponent: s64) {
    left := exponent;

    while left >= 9 {
        big_mul_small(b, 1_000_000_000);
        left -= 9;
    }

    if left > 0 {
        power: u32 = 1;
        for 1..left power *= 10;
        big_mul_small(b, power);
    }
}

// Powers of ten that are exact in each format, for the one-operation fast path.
EXACT_POWERS_64 :: float64.[1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22];
EXACT_POWERS_32 :: float32.[1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10];

signed_infinity_64 :: (negative: bool) -> float64 {
    bits: u64 = 0x7ff0_0000_0000_0000;
    if negative bits |= 0x8000_0000_0000_0000;
    return cast,force(float64) bits;
}

signed_infinity_32 :: (negative: bool) -> float32 {
    bits: u32 = 0x7f80_0000;
    if negative bits |= 0x8000_0000;
    return cast,force(float32) bits;
}

// Rounds the decimal to `mantissa_bits` bits (53 or 24). Returns the mantissa and the power of
// two to scale it by, or overflow. A mantissa below 2^(mantissa_bits - 1) is a subnormal.
decimal_to_binary :: (d: *Decimal_Float, mantissa_bits: s64, min_exponent: s64) -> u64, s64, bool {
    if d.count == 0 return 0, 0, false;

    magnitude := d.count + d.exponent; // the value is in [10^(magnitude-1), 10^magnitude)
    limit := ifx mantissa_bits == 53 then 309 else 39;
    floor := ifx mantissa_bits == 53 then -324 else -46;

    if magnitude > limit return 0, 0, true;
    if magnitude <= floor return 0, 0, false;

    numerator: Big = ---;
    denominator: Big = ---;

    big_set_small(*numerator, 0);

    at := 0;

    while at < d.count {
        chunk: u32;
        power: u32 = 1;
        taken := 0;

        while at < d.count && taken < 9 {
            chunk = chunk * 10 + d.digits[at];
            power *= 10;
            at += 1;
            taken += 1;
        }

        if numerator.n == 0 big_set_small(*numerator, chunk);
        else {
            big_mul_small(*numerator, power);
            big_add_small(*numerator, chunk);
        }
    }

    exponent := d.exponent;

    if d.truncated {
        big_mul_small(*numerator, 10);
        big_add_small(*numerator, 1);
        exponent -= 1;
    }

    big_set_small(*denominator, 1);

    if exponent >= 0 big_mul_pow10(*numerator, exponent);
    else big_mul_pow10(*denominator, -exponent);

    // Scale so the quotient has mantissa_bits + 2 or + 3 bits.
    shift := mantissa_bits + 2 - (big_bit_length(*numerator) - big_bit_length(*denominator));

    if shift >= 0 big_shift_left(*numerator, shift);
    else big_shift_left(*denominator, -shift);

    top := mantissa_bits + 2;
    window := denominator;

    big_shift_left(*window, top);

    quotient: u64;
    i := top;

    while i >= 0 {
        if big_cmp(*numerator, *window) >= 0 {
            big_sub(*numerator, *window);
            quotient |= (cast(u64) 1) << cast(u64) i;
        }

        big_shift_right_one(*window);
        i -= 1;
    }

    sticky := numerator.n != 0;

    // quotient * 2^-shift, with the remainder below one unit of its last bit.
    length := 0;
    probe := quotient;

    while probe {
        length += 1;
        probe >>= 1;
    }

    leading := length - 1 - shift; // the exponent of the top bit

    precision := mantissa_bits;

    if leading < min_exponent precision = mantissa_bits - (min_exponent - leading);

    drop := length - precision;
    mantissa: u64;

    if drop > length {
        mantissa = 0;
    } else if drop == length {
        // Everything is below the lowest bit: only the half bit and the rest decide.
        half := (cast(u64) 1) << cast(u64) (drop - 1);
        mantissa = ifx quotient > half || (quotient == half && sticky) then 1 else 0;
    } else {
        mantissa = quotient >> cast(u64) drop;
        remainder := quotient & (((cast(u64) 1) << cast(u64) drop) - 1);
        half := (cast(u64) 1) << cast(u64) (drop - 1);

        if remainder > half || (remainder == half && (sticky || (mantissa & 1) == 1)) mantissa += 1;
    }

    return mantissa, drop - shift, false;
}

#scope_export

// The most significant digits kept from a number; later nonzero digits only set `truncated`.
MAX_DECIMAL_FLOAT_DIGITS :: 800;

// A decimal number as digits times 10^exponent. `digits` hold values 0..9 with no leading or
// trailing zeros; `count == 0` means zero. Fill it with scan_decimal_float or by hand.
Decimal_Float :: struct {
    negative: bool;
    digits: [MAX_DECIMAL_FLOAT_DIGITS] u8;
    count: s64;
    exponent: s64; // the value is the digits as an integer times 10^exponent
    truncated: bool;
}

// Reads `[+-] digits [. digits] [e [+-] digits]` at the start of `text` (no spaces; at least one
// mantissa digit) into `d` and returns the bytes used, or 0 when there is no number. An "e" with
// no digits after it is left unread. With `limit_exponent` an exponent beyond a few hundred makes
// the whole scan fail; without it the exponent saturates, so "1e999999999" is an overflow and
// "1e-999999999" is zero. `d` can be left uninitialised (`d: Decimal_Float = ---;`).
scan_decimal_float :: (text: string, d: *Decimal_Float, limit_exponent: bool) -> s64 {
    d.negative = false;
    d.count = 0;
    d.exponent = 0;
    d.truncated = false;

    position: s64 = 0;

    if text.count > 0 {
        if text[0] == #char "-" {
            d.negative = true;
            position += 1;
        } else if text[0] == #char "+" position += 1;
    }

    seen: s64 = 0;
    in_fraction := false;

    while position < text.count {
        c := text[position];

        if c == #char "." {
            if in_fraction break;
            in_fraction = true;
        } else if c >= #char "0" && c <= #char "9" {
            digit := c - #char "0";

            seen += 1;

            if d.count == 0 && digit == 0 {
                if in_fraction d.exponent -= 1;
            } else if d.count < MAX_DECIMAL_FLOAT_DIGITS {
                d.digits[d.count] = digit;
                d.count += 1;
                if in_fraction d.exponent -= 1;
            } else {
                if digit != 0 d.truncated = true;
                if !in_fraction d.exponent += 1;
            }
        } else break;

        position += 1;
    }

    if seen == 0 return 0;

    if position < text.count && (text[position] == #char "e" || text[position] == #char "E") {
        exponent_start := position;

        position += 1;
        exponent_negative := false;

        if position < text.count {
            if text[position] == #char "-" {
                exponent_negative = true;
                position += 1;
            } else if text[position] == #char "+" position += 1;
        }

        exponent_digits := position;
        exponent: s64 = 0;

        while position < text.count {
            c := text[position];
            if c < #char "0" || c > #char "9" break;

            if limit_exponent {
                if exponent > 400 return 0;
                exponent = exponent * 10 + c - #char "0";
            } else if exponent < 1_000_000 exponent = exponent * 10 + c - #char "0";

            position += 1;
        }

        if exponent_digits == position position = exponent_start;
        else {
            if limit_exponent && exponent > 4000 return 0;
            d.exponent += ifx exponent_negative then -exponent else exponent;
        }
    }

    while d.count > 0 && d.digits[d.count - 1] == 0 {
        d.count -= 1;
        d.exponent += 1;
    }

    return position;
}

// The float64 nearest the decimal (ties to even, subnormals included). Past the largest finite
// value the result is an infinity of the decimal's sign and `overflow` is true.
decimal_float_to_float64 :: (d: *Decimal_Float) -> float64, overflow: bool {
    value: float64;

    if d.count <= 19 && !d.truncated {
        small: u64;
        for 0..d.count - 1 small = small * 10 + d.digits[it];

        if small <= (cast(u64) 1) << 53 && d.exponent >= -22 && d.exponent <= 22 {
            value = cast(float64) small;
            value = ifx d.exponent >= 0 then value * EXACT_POWERS_64[d.exponent] else value / EXACT_POWERS_64[-d.exponent];

            return ifx d.negative then -value else value, false;
        }
    }

    mantissa, scale, overflow := decimal_to_binary(d, 53, -1022);

    if overflow return signed_infinity_64(d.negative), true;

    bits: u64;

    if mantissa >= (cast(u64) 1) << 52 {
        exponent := scale + 52 + 1023;
        extra := mantissa;

        if extra == (cast(u64) 1) << 53 {
            extra = (cast(u64) 1) << 52;
            exponent += 1;
        }

        if exponent >= 2047 return signed_infinity_64(d.negative), true;

        bits = (cast(u64) exponent << 52) | (extra - ((cast(u64) 1) << 52));
    } else {
        bits = mantissa; // subnormal or zero
    }

    value = cast,force(float64) bits;

    return ifx d.negative then -value else value, false;
}

// The same for float32, rounded once from the exact decimal, never through a float64.
decimal_float_to_float32 :: (d: *Decimal_Float) -> float32, overflow: bool {
    value: float32;

    if d.count <= 9 && !d.truncated {
        small: u64;
        for 0..d.count - 1 small = small * 10 + d.digits[it];

        if small <= (cast(u64) 1) << 24 && d.exponent >= -10 && d.exponent <= 10 {
            value = cast(float32) small;
            value = ifx d.exponent >= 0 then value * EXACT_POWERS_32[d.exponent] else value / EXACT_POWERS_32[-d.exponent];

            return ifx d.negative then -value else value, false;
        }
    }

    mantissa, scale, overflow := decimal_to_binary(d, 24, -126);

    if overflow return signed_infinity_32(d.negative), true;

    bits: u32;

    if mantissa >= (cast(u64) 1) << 23 {
        exponent := scale + 23 + 127;
        extra := mantissa;

        if extra == (cast(u64) 1) << 24 {
            extra = (cast(u64) 1) << 23;
            exponent += 1;
        }

        if exponent >= 255 return signed_infinity_32(d.negative), true;

        bits = cast,no_check(u32) ((cast(u64) exponent << 23) | (extra - ((cast(u64) 1) << 23)));
    } else {
        bits = cast,no_check(u32) mantissa;
    }

    value = cast,force(float32) bits;

    return ifx d.negative then -value else value, false;
}
