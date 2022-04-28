/// The values for this enum are chosen so that:
/// 1. value & 0xFF gives number of bits per channel
/// 2. value & 0xF00 gives number of channels
/// 3. value & 0xF000 gives a special variant number, 1 for Bgr, 2 for Float and 3 for special Rgb 565
/// Note that palette index formats have number of channels set to 0.
pub const PixelFormat = enum(u32) {
    Index1 = 1,
    Index2 = 2,
    Index4 = 4,
    Index8 = 8,
    Index16 = 16,
    Grayscale1 = 0x101,
    Grayscale2 = 0x102,
    Grayscale4 = 0x104,
    Grayscale8 = 0x108,
    Grayscale16 = 0x110,
    Grayscale8Alpha = 0x208,
    Grayscale16Alpha = 0x210,
    Rgb565 = 0x3305,
    Rgb555 = 0x305,
    Rgb24 = 0x308,
    Rgba32 = 0x408,
    Bgr24 = 0x1308,
    Bgra32 = 0x1408,
    Rgb48 = 0x310,
    Rgba64 = 0x410,
    Float32 = 0x2420,

    const Self = @This();

    pub fn isJustGrayscale(self: Self) bool {
        return @enumToInt(self) & 0xf00 == 0x100;
    }

    pub fn isIndex(self: Self) bool {
        return @enumToInt(self) <= @enumToInt(PixelFormat.Index16);
    }

    pub fn isStandardRgb(self: Self) bool {
        return self == .Rgb24 or self == .Rgb48;
    }

    pub fn isRgba(self: Self) bool {
        return self == .Rgba32 or self == .Rgba64;
    }

    pub fn is16Bit(self: Self) bool {
        return @enumToInt(self) & 0xff == 0x10;
    }

    pub fn getPixelStride(self: Self) u8 {
        // TODO: Test if there is speed diff
        var enumVal = @enumToInt(self);
        var channels = (enumVal & 0xf00) >> 8;
        if (channels == 0) channels = 1;
        return @intCast(u8, (channels * (enumVal & 0xff) + 7) / 8);
        // return switch (self) {
        //     .Index1, .Index2, .Index4, .Index8,
        //     .Grayscale1, .Grayscale2, .Grayscale4, .Grayscale8 => 1,
        //     .Index16, .Grayscale16, .Grayscale8Alpha, .Rgb565, .Rgb555 => 2,
        //     .Rgb24, .Bgr24 => 3,
        //     .Grayscale16Alpha, .Rgba32, .Bgra32 => 4,
        //     .Rgb48 => 6,
        //     .Rgba64 => 8,
        //     .Float32 => 16,
        // };
    }
};

test "GetPixelStride" {
    const std = @import("std");
    const fields = @typeInfo(PixelFormat).Enum.fields;
    inline for (fields) |field| {
        const val = @intToEnum(PixelFormat, field.value);
        const expected: u8 = switch (val) {
            .Index1, .Index2, .Index4, .Index8, .Grayscale1, .Grayscale2, .Grayscale4, .Grayscale8 => 1,
            .Index16, .Grayscale16, .Grayscale8Alpha, .Rgb565, .Rgb555 => 2,
            .Rgb24, .Bgr24 => 3,
            .Grayscale16Alpha, .Rgba32, .Bgra32 => 4,
            .Rgb48 => 6,
            .Rgba64 => 8,
            .Float32 => 16,
        };
        try std.testing.expectEqual(expected, val.getPixelStride());
    }
}
