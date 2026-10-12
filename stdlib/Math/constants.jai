// Integer limits first, then float limits, then the circle constants.
U8_MAX: u8 : 255;
U16_MAX: u16 : 65535;
U32_MAX: u32 : 0xffff_ffff;
U64_MAX: u64 : 0xffff_ffff_ffff_ffff;
S8_MAX: s8 : 127;
S8_MIN: s8 : -128;
S16_MAX: s16 : 32767;
S16_MIN: s16 : -32768;
S32_MAX: s32 : 0x7fff_ffff;
S32_MIN: s32 : -2147483648;
S64_MAX: s64 : 0x7fff_ffff_ffff_ffff;
S64_MIN: s64 : -9223372036854775808;

FLOAT64_MAX: float64 : 0h7FEFFFFF_FFFFFFFF;
FLOAT64_MIN: float64 : 0h00100000_00000000;
FLOAT64_INFINITY: float64 : 0h7FF00000_00000000;
FLOAT64_NAN: float64 : 0h7FF7FFFF_FFFFFFFF;
FLOAT32_MAX: float32 : 0h7F7FFFFF;
FLOAT32_MIN: float32 : 0h00800000;
FLOAT32_INFINITY: float32 : 0h7F800000;
FLOAT32_NAN: float32 : 0h7FBFFFFF;
FLOAT16_MAX: float : 65504.0;

PI64: float64 : 3.141592653589793;
PI32 :: cast(float32) PI;
PI :: cast(float32) 3.1415927;
TAU64: float64 : 6.28318530717958648;
TAU32 :: cast(float32) TAU;
TAU :: cast(float32) 6.283185;
