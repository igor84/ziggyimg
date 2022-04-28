/// The values for this enum are chosen so that:
/// 1. value & 0xFF gives number of bits per channel
/// 2. value & 0xF00 gives number of channels
/// 3. value & 0xF000 gives a special variant number, 1 for Bgr, 2 for Float and 3 for special Rgb 565
/// Note that palette index formats have number of channels set to 0.
pub const PixelFormat = enum(u32) {
    index1 = 1,
    index2 = 2,
    index4 = 4,
    index8 = 8,
    index16 = 16,
    grayscale1 = 0x101,
    grayscale2 = 0x102,
    grayscale4 = 0x104,
    grayscale8 = 0x108,
    grayscale16 = 0x110,
    grayscale8Alpha = 0x208,
    grayscale16Alpha = 0x210,
    rgb565 = 0x3305,
    rgb555 = 0x305,
    rgb24 = 0x308,
    rgba32 = 0x408,
    bgr24 = 0x1308,
    bgra32 = 0x1408,
    rgb48 = 0x310,
    rgba64 = 0x410,
    float32 = 0x2420,

    const Self = @This();

    pub fn isJustGrayscale(self: Self) bool {
        return @enumToInt(self) & 0xf00 == 0x100;
    }

    pub fn isIndex(self: Self) bool {
        return @enumToInt(self) <= @enumToInt(PixelFormat.index16);
    }

    pub fn isStandardRgb(self: Self) bool {
        return self == .rgb24 or self == .rgb48;
    }

    pub fn isRgba(self: Self) bool {
        return self == .rgba32 or self == .rgba64;
    }

    pub fn is16Bit(self: Self) bool {
        return @enumToInt(self) & 0xff == 0x10;
    }

    pub fn getPixelStride(self: Self) u8 {
        // TODO: Test if there is speed diff
        var enum_val = @enumToInt(self);
        var channels = (enum_val & 0xf00) >> 8;
        if (channels == 0) channels = 1;
        return @intCast(u8, (channels * (enum_val & 0xff) + 7) / 8);
        // return switch (self) {
        //     .index1, .index2, .index4, .index8,
        //     .grayscale1, .grayscale2, .grayscale4, .grayscale8 => 1,
        //     .index16, .grayscale16, .grayscale8Alpha, .rgb565, .rgb555 => 2,
        //     .rgb24, .bgr24 => 3,
        //     .grayscale16Alpha, .rgba32, .bgra32 => 4,
        //     .rgb48 => 6,
        //     .rgba64 => 8,
        //     .float32 => 16,
        // };
    }
};

test "GetPixelStride" {
    const std = @import("std");
    const fields = @typeInfo(PixelFormat).Enum.fields;
    inline for (fields) |field| {
        const val = @intToEnum(PixelFormat, field.value);
        const expected: u8 = switch (val) {
            .index1, .index2, .index4, .index8, .grayscale1, .grayscale2, .grayscale4, .grayscale8 => 1,
            .index16, .grayscale16, .grayscale8Alpha, .rgb565, .rgb555 => 2,
            .rgb24, .bgr24 => 3,
            .grayscale16Alpha, .rgba32, .bgra32 => 4,
            .rgb48 => 6,
            .rgba64 => 8,
            .float32 => 16,
        };
        try std.testing.expectEqual(expected, val.getPixelStride());
    }
}
