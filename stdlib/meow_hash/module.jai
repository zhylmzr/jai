// Meow hash 0.5 ("calico") for x64: the 128-bit non-cryptographic hash built from AES rounds,
// bit-exact with the published algorithm (the digests of the reference implementation are the
// test vectors in tests/stdlib/meow-hash.jai).
//
// Eight 16-byte lanes start from a 128-byte seed. Each whole 256-byte block of input is folded in
// by eight overlapping stages (`aesdec` plus 64-bit adds and xors). What is left over is then
// handled in three steps: the final partial 32 bytes, zero extended, and the byte count are
// folded in as two more stages, up to seven whole 32-byte pieces of the remainder get one stage
// each, and twelve shuffle rounds followed by a short fold squeeze the lanes into 128 bits.
//
// `MeowHash` is a macro because the result lives in a `#asm` vector register declared by the
// caller (`#asm { hash: vec; }`): registers cannot be passed by value to a procedure, so the
// macro takes the register's name as code and fills its 16 low bytes. `MeowU64From` reads one
// 64-bit lane out of such a register. Everything that needs `aesdec` is only compiled for x64;
// other targets use whatever fallback the caller selects with `#if CPU == .X64`.

#if CPU == .X64 {
    // Hashes `len` bytes at `source` into the 16 bytes at `out`.
    meow_hash_bytes :: (seed: *u8, len: u64, source: *u8, out: *u8) {
        state: [128] u8;
        s := state.data;

        for 0..127 s[it] = seed[it];

        p := source;
        remaining := len;

        while remaining >= 256 {
            #asm {
            x0: vec; x1: vec; x2: vec; x3: vec; x4: vec; x5: vec; x6: vec; x7: vec;
            movdqu x0, [s + 0];
            movdqu x1, [s + 16];
            movdqu x2, [s + 32];
            movdqu x3, [s + 48];
            movdqu x4, [s + 64];
            movdqu x5, [s + 80];
            movdqu x6, [s + 96];
            movdqu x7, [s + 112];
            aesdec x0, x4;
            paddq x6, [p + 15];
            pxor x4, [p + 0];
            aesdec x4, x1;
            paddq x2, [p + 1];
            pxor x1, [p + 16];
            aesdec x1, x5;
            paddq x7, [p + 47];
            pxor x5, [p + 32];
            aesdec x5, x2;
            paddq x3, [p + 33];
            pxor x2, [p + 48];
            aesdec x2, x6;
            paddq x0, [p + 79];
            pxor x6, [p + 64];
            aesdec x6, x3;
            paddq x4, [p + 65];
            pxor x3, [p + 80];
            aesdec x3, x7;
            paddq x1, [p + 111];
            pxor x7, [p + 96];
            aesdec x7, x4;
            paddq x5, [p + 97];
            pxor x4, [p + 112];
            aesdec x4, x0;
            paddq x2, [p + 143];
            pxor x0, [p + 128];
            aesdec x0, x5;
            paddq x6, [p + 129];
            pxor x5, [p + 144];
            aesdec x5, x1;
            paddq x3, [p + 175];
            pxor x1, [p + 160];
            aesdec x1, x6;
            paddq x7, [p + 161];
            pxor x6, [p + 176];
            aesdec x6, x2;
            paddq x4, [p + 207];
            pxor x2, [p + 192];
            aesdec x2, x7;
            paddq x0, [p + 193];
            pxor x7, [p + 208];
            aesdec x7, x3;
            paddq x5, [p + 239];
            pxor x3, [p + 224];
            aesdec x3, x0;
            paddq x1, [p + 225];
            pxor x0, [p + 240];
            movdqu [s + 0], x0;
            movdqu [s + 16], x1;
            movdqu [s + 32], x2;
            movdqu [s + 48], x3;
            movdqu [s + 64], x4;
            movdqu [s + 80], x5;
            movdqu [s + 96], x6;
            movdqu [s + 112], x7;
            }

            p += 256;
            remaining -= 256;
        }

        // The tail: the last (len mod 16) bytes sit in `last_part`, zero extended. When bit 4 of
        // the length is set the 16 bytes before them are a second piece, and `extra` holds the
        // eight 16-byte values that the two closing stages add or xor in.
        extra: [128] u8;
        e := extra.data;
        whole := len & ~cast(u64) 15;
        last_part: [16] u8;

        for 0..cast(s64) (len & 15) - 1 last_part[it] = source[whole + cast(u64) it];
        before: [16] u8;

        if (len & 16) != 0 {
            before = last_part;
            for 0..15 last_part[it] = source[whole - 16 + cast(u64) it];
        }

        // `before` followed by `last_part` read one byte further right, and one byte further left.
        extra[0] = before[15];
        for 0..14 extra[1 + it] = last_part[it];
        for 0..15 extra[16 + it] = last_part[it];
        for 0..14 extra[32 + it] = before[1 + it];
        extra[47] = last_part[0];
        for 0..15 extra[48 + it] = before[it];

        // Bytes 64..95 stay zero (the unused nonce); the length goes in at 96 and, shifted by one byte, at 112.
        for 0..7 {
            extra[112 + it] = cast,trunc(u8) (len >> cast(u64) (8 * it));
            if it > 0 extra[96 + it - 1] = cast,trunc(u8) (len >> cast(u64) (8 * it));
        }

        #asm {
          x0: vec; x1: vec; x2: vec; x3: vec; x4: vec; x5: vec; x6: vec; x7: vec;
          movdqu x0, [s + 0];
          movdqu x1, [s + 16];
          movdqu x2, [s + 32];
          movdqu x3, [s + 48];
          movdqu x4, [s + 64];
          movdqu x5, [s + 80];
          movdqu x6, [s + 96];
          movdqu x7, [s + 112];
          aesdec x0, x4;
          paddq x6, [e + 0];
          pxor x4, [e + 16];
          aesdec x4, x1;
          paddq x2, [e + 32];
          pxor x1, [e + 48];
          aesdec x1, x5;
          paddq x7, [e + 64];
          pxor x5, [e + 80];
          aesdec x5, x2;
          paddq x3, [e + 96];
          pxor x2, [e + 112];
          movdqu [s + 0], x0;
          movdqu [s + 16], x1;
          movdqu [s + 32], x2;
          movdqu [s + 48], x3;
          movdqu [s + 64], x4;
          movdqu [s + 80], x5;
          movdqu [s + 96], x6;
          movdqu [s + 112], x7;
        }

        // Up to seven whole 32-byte pieces of the remainder, one stage each.
        pieces := (len >> 5) & 7;
        if pieces > 0 {
            #asm {
        x0: vec; x1: vec; x2: vec; x3: vec; x4: vec; x5: vec; x6: vec; x7: vec;
        movdqu x0, [s + 0];
        movdqu x1, [s + 16];
        movdqu x2, [s + 32];
        movdqu x3, [s + 48];
        movdqu x4, [s + 64];
        movdqu x5, [s + 80];
        movdqu x6, [s + 96];
        movdqu x7, [s + 112];
        aesdec x2, x6;
        paddq x0, [p + 15];
        pxor x6, [p + 0];
        aesdec x6, x3;
        paddq x4, [p + 1];
        pxor x3, [p + 16];
        movdqu [s + 0], x0;
        movdqu [s + 16], x1;
        movdqu [s + 32], x2;
        movdqu [s + 48], x3;
        movdqu [s + 64], x4;
        movdqu [s + 80], x5;
        movdqu [s + 96], x6;
        movdqu [s + 112], x7;
            }
        }

        if pieces > 1 {
            #asm {
        x0: vec; x1: vec; x2: vec; x3: vec; x4: vec; x5: vec; x6: vec; x7: vec;
        movdqu x0, [s + 0];
        movdqu x1, [s + 16];
        movdqu x2, [s + 32];
        movdqu x3, [s + 48];
        movdqu x4, [s + 64];
        movdqu x5, [s + 80];
        movdqu x6, [s + 96];
        movdqu x7, [s + 112];
        aesdec x3, x7;
        paddq x1, [p + 47];
        pxor x7, [p + 32];
        aesdec x7, x4;
        paddq x5, [p + 33];
        pxor x4, [p + 48];
        movdqu [s + 0], x0;
        movdqu [s + 16], x1;
        movdqu [s + 32], x2;
        movdqu [s + 48], x3;
        movdqu [s + 64], x4;
        movdqu [s + 80], x5;
        movdqu [s + 96], x6;
        movdqu [s + 112], x7;
            }
        }

        if pieces > 2 {
            #asm {
        x0: vec; x1: vec; x2: vec; x3: vec; x4: vec; x5: vec; x6: vec; x7: vec;
        movdqu x0, [s + 0];
        movdqu x1, [s + 16];
        movdqu x2, [s + 32];
        movdqu x3, [s + 48];
        movdqu x4, [s + 64];
        movdqu x5, [s + 80];
        movdqu x6, [s + 96];
        movdqu x7, [s + 112];
        aesdec x4, x0;
        paddq x2, [p + 79];
        pxor x0, [p + 64];
        aesdec x0, x5;
        paddq x6, [p + 65];
        pxor x5, [p + 80];
        movdqu [s + 0], x0;
        movdqu [s + 16], x1;
        movdqu [s + 32], x2;
        movdqu [s + 48], x3;
        movdqu [s + 64], x4;
        movdqu [s + 80], x5;
        movdqu [s + 96], x6;
        movdqu [s + 112], x7;
            }
        }

        if pieces > 3 {
            #asm {
        x0: vec; x1: vec; x2: vec; x3: vec; x4: vec; x5: vec; x6: vec; x7: vec;
        movdqu x0, [s + 0];
        movdqu x1, [s + 16];
        movdqu x2, [s + 32];
        movdqu x3, [s + 48];
        movdqu x4, [s + 64];
        movdqu x5, [s + 80];
        movdqu x6, [s + 96];
        movdqu x7, [s + 112];
        aesdec x5, x1;
        paddq x3, [p + 111];
        pxor x1, [p + 96];
        aesdec x1, x6;
        paddq x7, [p + 97];
        pxor x6, [p + 112];
        movdqu [s + 0], x0;
        movdqu [s + 16], x1;
        movdqu [s + 32], x2;
        movdqu [s + 48], x3;
        movdqu [s + 64], x4;
        movdqu [s + 80], x5;
        movdqu [s + 96], x6;
        movdqu [s + 112], x7;
            }
        }

        if pieces > 4 {
            #asm {
        x0: vec; x1: vec; x2: vec; x3: vec; x4: vec; x5: vec; x6: vec; x7: vec;
        movdqu x0, [s + 0];
        movdqu x1, [s + 16];
        movdqu x2, [s + 32];
        movdqu x3, [s + 48];
        movdqu x4, [s + 64];
        movdqu x5, [s + 80];
        movdqu x6, [s + 96];
        movdqu x7, [s + 112];
        aesdec x6, x2;
        paddq x4, [p + 143];
        pxor x2, [p + 128];
        aesdec x2, x7;
        paddq x0, [p + 129];
        pxor x7, [p + 144];
        movdqu [s + 0], x0;
        movdqu [s + 16], x1;
        movdqu [s + 32], x2;
        movdqu [s + 48], x3;
        movdqu [s + 64], x4;
        movdqu [s + 80], x5;
        movdqu [s + 96], x6;
        movdqu [s + 112], x7;
            }
        }

        if pieces > 5 {
            #asm {
        x0: vec; x1: vec; x2: vec; x3: vec; x4: vec; x5: vec; x6: vec; x7: vec;
        movdqu x0, [s + 0];
        movdqu x1, [s + 16];
        movdqu x2, [s + 32];
        movdqu x3, [s + 48];
        movdqu x4, [s + 64];
        movdqu x5, [s + 80];
        movdqu x6, [s + 96];
        movdqu x7, [s + 112];
        aesdec x7, x3;
        paddq x5, [p + 175];
        pxor x3, [p + 160];
        aesdec x3, x0;
        paddq x1, [p + 161];
        pxor x0, [p + 176];
        movdqu [s + 0], x0;
        movdqu [s + 16], x1;
        movdqu [s + 32], x2;
        movdqu [s + 48], x3;
        movdqu [s + 64], x4;
        movdqu [s + 80], x5;
        movdqu [s + 96], x6;
        movdqu [s + 112], x7;
            }
        }

        if pieces > 6 {
            #asm {
        x0: vec; x1: vec; x2: vec; x3: vec; x4: vec; x5: vec; x6: vec; x7: vec;
        movdqu x0, [s + 0];
        movdqu x1, [s + 16];
        movdqu x2, [s + 32];
        movdqu x3, [s + 48];
        movdqu x4, [s + 64];
        movdqu x5, [s + 80];
        movdqu x6, [s + 96];
        movdqu x7, [s + 112];
        aesdec x0, x4;
        paddq x6, [p + 207];
        pxor x4, [p + 192];
        aesdec x4, x1;
        paddq x2, [p + 193];
        pxor x1, [p + 208];
        movdqu [s + 0], x0;
        movdqu [s + 16], x1;
        movdqu [s + 32], x2;
        movdqu [s + 48], x3;
        movdqu [s + 64], x4;
        movdqu [s + 80], x5;
        movdqu [s + 96], x6;
        movdqu [s + 112], x7;
            }
        }

        o := out;

        #asm {
        x0: vec; x1: vec; x2: vec; x3: vec; x4: vec; x5: vec; x6: vec; x7: vec;
        movdqu x0, [s + 0];
        movdqu x1, [s + 16];
        movdqu x2, [s + 32];
        movdqu x3, [s + 48];
        movdqu x4, [s + 64];
        movdqu x5, [s + 80];
        movdqu x6, [s + 96];
        movdqu x7, [s + 112];
        aesdec x0, x4;
        paddq x1, x5;
        pxor x4, x6;
        aesdec x4, x1;
        paddq x5, x6;
        pxor x1, x2;
        aesdec x1, x5;
        paddq x2, x6;
        pxor x5, x7;
        aesdec x5, x2;
        paddq x6, x7;
        pxor x2, x3;
        aesdec x2, x6;
        paddq x3, x7;
        pxor x6, x0;
        aesdec x6, x3;
        paddq x7, x0;
        pxor x3, x4;
        aesdec x3, x7;
        paddq x4, x0;
        pxor x7, x1;
        aesdec x7, x4;
        paddq x0, x1;
        pxor x4, x5;
        aesdec x4, x0;
        paddq x5, x1;
        pxor x0, x2;
        aesdec x0, x5;
        paddq x1, x2;
        pxor x5, x6;
        aesdec x5, x1;
        paddq x6, x2;
        pxor x1, x3;
        aesdec x1, x6;
        paddq x2, x3;
        pxor x6, x7;
        aesdec x6, x2;
        paddq x7, x3;
        pxor x2, x4;
        aesdec x2, x7;
        paddq x3, x4;
        pxor x7, x0;
        aesdec x7, x3;
        paddq x0, x4;
        pxor x3, x5;
        aesdec x3, x0;
        paddq x4, x5;
        pxor x0, x1;
        aesdec x0, x4;
        paddq x1, x5;
        pxor x4, x6;
        aesdec x4, x1;
        paddq x5, x6;
        pxor x1, x2;
        aesdec x1, x5;
        paddq x2, x6;
        pxor x5, x7;
        aesdec x5, x2;
        paddq x6, x7;
        pxor x2, x3;
        aesdec x2, x6;
        paddq x3, x7;
        pxor x6, x0;
        aesdec x6, x3;
        paddq x7, x0;
        pxor x3, x4;
        aesdec x3, x7;
        paddq x4, x0;
        pxor x7, x1;
        aesdec x7, x4;
        paddq x0, x1;
        pxor x4, x5;
        paddq x0, x2;
        paddq x1, x3;
        paddq x4, x6;
        paddq x5, x7;
        pxor x0, x1;
        pxor x4, x5;
        paddq x0, x4;
        movdqu [o], x0;
        }
    }

    MeowHash :: (seed: [128] u8, len: u64, source: *void, hash: Code) #expand {
        out := cast(*u8) *(#insert hash);
        seed_copy := seed;
        meow_hash_bytes(seed_copy.data, len, cast(*u8) source, out);
    }

    MeowU64From :: (hash: Code, index: u32) -> u64 #expand {
        lanes := cast(*u64) *(#insert hash);
        return lanes[index];
    }
}

// The first 256 hexadecimal digits of pi (0x3.243F6A88...).
MeowDefaultSeed: [128] u8 = u8.[
    0x32, 0x43, 0xF6, 0xA8, 0x88, 0x5A, 0x30, 0x8D,
    0x31, 0x31, 0x98, 0xA2, 0xE0, 0x37, 0x07, 0x34,
    0x4A, 0x40, 0x93, 0x82, 0x22, 0x99, 0xF3, 0x1D,
    0x00, 0x82, 0xEF, 0xA9, 0x8E, 0xC4, 0xE6, 0xC8,
    0x94, 0x52, 0x82, 0x1E, 0x63, 0x8D, 0x01, 0x37,
    0x7B, 0xE5, 0x46, 0x6C, 0xF3, 0x4E, 0x90, 0xC6,
    0xCC, 0x0A, 0xC2, 0x9B, 0x7C, 0x97, 0xC5, 0x0D,
    0xD3, 0xF8, 0x4D, 0x5B, 0x5B, 0x54, 0x70, 0x91,
    0x79, 0x21, 0x6D, 0x5D, 0x98, 0x97, 0x9F, 0xB1,
    0xBD, 0x13, 0x10, 0xBA, 0x69, 0x8D, 0xFB, 0x5A,
    0xC2, 0xFF, 0xD7, 0x2D, 0xBD, 0x01, 0xAD, 0xFB,
    0x7B, 0x8E, 0x1A, 0xFE, 0xD6, 0xA2, 0x67, 0xE9,
    0x6B, 0xA7, 0xC9, 0x04, 0x5F, 0x12, 0xC7, 0xF9,
    0x92, 0x4A, 0x19, 0x94, 0x7B, 0x39, 0x16, 0xCF,
    0x70, 0x80, 0x1F, 0x2E, 0x28, 0x58, 0xEF, 0xC1,
    0x66, 0x36, 0x92, 0x0D, 0x87, 0x15, 0x74, 0xE6,
];

MEOW_PAGESIZE :: 4096;
MEOW_PREFETCH :: 4096;
MEOW_PREFETCH_LIMIT :: 0x3ff;

MEOW_HASH_VERSION :: 5;
MEOW_HASH_VERSION_NAME :: "0.5/calico";
