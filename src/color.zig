const std = @import("std");
const math = std.math;

pub const colorspace = @import("color/colorspace.zig");

/// This implements [CIE XYZ](https://en.wikipedia.org/wiki/CIE_1931_color_space)
/// color types. These color spaces represent the simplest expression of the
/// full-spectrum of human visible color. No attempts are made to support
/// perceptual uniformity, or meaningful color blending within these color
/// spaces. They are most useful as an absolute representation of human visible
/// colors, and a centre point for color space conversions.
pub const XYZ = struct {
    X: f32,
    Y: f32,
    Z: f32,

    pub fn init(x: f32, y: f32, z: f32) XYZ {
        return XYZ{ .X = x, .Y = y, .Z = z };
    }

    pub fn toxyY(self: XYZ) xyY {
        var sum = self.X + self.Y + self.Z;
        if (sum != 0) return xyY.init(self.X / sum, self.Y / sum, self.Y);

        return xyY.init(std_illuminant.D65.x, std_illuminant.D65.y, 0);
    }

    pub inline fn equal(self: xyY, other: xyY) bool {
        return self.Y == other.Y and self.X == other.X and self.Z == other.Z;
    }

    pub inline fn approxEqual(self: xyY, other: xyY, epsilon: f32) bool {
        return math.approxEqAbs(f32, self.Y, other.Y, epsilon) and
            math.approxEqAbs(f32, self.X, other.X, epsilon) and
            math.approxEqAbs(f32, self.Z, other.Z, epsilon);
    }
};

/// This implements [CIE xyY](https://en.wikipedia.org/wiki/CIE_1931_color_space#CIE_xy_chromaticity_diagram_and_the_CIE_xyY_color_space)
/// color types. These color spaces represent the simplest expression of the
/// full-spectrum of human visible color. No attempts are made to support
/// perceptual uniformity, or meaningful color blending within these color
/// spaces. They are most useful as an absolute representation of human visible
/// colors, and a centre point for color space conversions.
pub const xyY = struct {
    x: f32,
    y: f32,
    Y: f32,

    pub fn init(x: f32, y: f32, Y: f32) xyY {
        return xyY{ .x = x, .y = y, .Y = Y };
    }

    pub fn toXYZ(self: xyY) XYZ {
        if (self.Y == 0) return XYZ.init(0, 0, 0);

        var ratio = self.Y / self.y;
        return XYZ.init(ratio * self.x, self.Y, ratio * (1 - self.x - self.y));
    }

    pub inline fn equal(self: xyY, other: xyY) bool {
        return self.Y == other.Y and self.x == other.x and self.y == other.y;
    }

    pub inline fn approxEqual(self: xyY, other: xyY, epsilon: f32) bool {
        return math.approxEqAbs(f32, self.Y, other.Y, epsilon) and
            math.approxEqAbs(f32, self.x, other.x, epsilon) and
            math.approxEqAbs(f32, self.y, other.y, epsilon);
    }
};

/// The illuminant values as defined on https://en.wikipedia.org/wiki/Standard_illuminant.
pub const std_illuminant = struct {
    /// Incandescent / Tungsten
    pub const A = xyY.init(0.44757, 0.40745, 1.00000);
    /// [obsolete] Direct sunlight at noon
    pub const B = xyY.init(0.34842, 0.35161, 1.00000);
    /// [obsolete] Average / North sky Daylight
    pub const C = xyY.init(0.31006, 0.31616, 1.00000);
    /// Horizon Light, ICC profile PCS (Profile connection space)
    pub const D50 = xyY.init(0.34567, 0.35850, 1.00000);
    /// Mid-morning / Mid-afternoon Daylight
    pub const D55 = xyY.init(0.33242, 0.34743, 1.00000);
    /// ACES Cinema
    pub const D60 = xyY.init(0.32168, 0.33767, 1.00000);
    /// Noon Daylight: Television, sRGB color space
    pub const D65 = xyY.init(0.31271, 0.32902, 1.00000);
    /// North sky Daylight
    pub const D75 = xyY.init(0.29902, 0.31485, 1.00000);
    /// Used by Japanese NTSC
    pub const D93 = xyY.init(0.28486, 0.29322, 1.00000);
    /// DCI-P3 digital cinema projector
    pub const DCI = xyY.init(0.31400, 0.35100, 1.00000);
    /// Equal energy
    pub const E = xyY.init(1.0 / 3.0, 1.0 / 3.0, 1.00000);
    /// Daylight Fluorescent
    pub const F1 = xyY.init(0.31310, 0.33727, 1.00000);
    /// Cool White Fluorescent
    pub const F2 = xyY.init(0.37208, 0.37529, 1.00000);
    /// White Fluorescent
    pub const F3 = xyY.init(0.40910, 0.39430, 1.00000);
    /// Warm White Fluorescent
    pub const F4 = xyY.init(0.44018, 0.40329, 1.00000);
    /// Daylight Fluorescent
    pub const F5 = xyY.init(0.31379, 0.34531, 1.00000);
    /// Lite White Fluorescent
    pub const F6 = xyY.init(0.37790, 0.38835, 1.00000);
    /// D65 simulator, Daylight simulator
    pub const F7 = xyY.init(0.31292, 0.32933, 1.00000);
    /// D50 simulator, Sylvania F40 Design 50
    pub const F8 = xyY.init(0.34588, 0.35875, 1.00000);
    /// Cool White Deluxe Fluorescent
    pub const F9 = xyY.init(0.37417, 0.37281, 1.00000);
    /// Philips TL85, Ultralume 50
    pub const F10 = xyY.init(0.34609, 0.35986, 1.00000);
    /// Philips TL84, Ultralume 40
    pub const F11 = xyY.init(0.38052, 0.37713, 1.00000);
    /// Philips TL83, Ultralume 30
    pub const F12 = xyY.init(0.43695, 0.40441, 1.00000);

    pub const values = [_]xyY{ A, B, C, D50, D55, D60, D65, D75, D93, DCI, E, F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12 };
    pub const names = [_][]const u8{ "A", "B", "C", "D50", "D55", "D60", "D65", "D75", "D93", "DCI", "E", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12" };

    pub fn getByName(name: []const u8) ?xyY {
        for (names) |n, index| {
            if (n.len != name.len) continue;
            if (n[0] != name[0]) continue;
            if (n.len > 1 and n[1] != name[1]) continue;
            if (n.len > 2 and n[2] != name[2]) continue;
            return values[index];
        }
        return null;
    }

    pub fn getName(stdIlluminant: xyY) ?[]const u8 {
        for (values) |value, i| {
            if (value.equal(stdIlluminant)) {
                return names[i];
            }
        }
        return null;
    }
};

fn getStdIlluminantsCount(comptime decls: anytype) u32 {
    comptime {
        var count = 0;
        while (@TypeOf(@field(std_illuminant, decls[count].name)) == xyY) {
            count += 1;
        }
        return count;
    }
}

pub inline fn toIntColor(comptime T: type, value: f32) T {
    return math.clamp(@floatToInt(T, math.round(value * @intToFloat(f32, math.maxInt(T)))), math.minInt(T), math.maxInt(T));
}

pub inline fn toF32Color(value: anytype) f32 {
    return @intToFloat(f32, value) / @intToFloat(f32, math.maxInt(@TypeOf(value)));
}

// *************** RGB Color representations ****************

pub const Colorf32 = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    const Self = @This();

    pub fn initRgb(r: f32, g: f32, b: f32) Self {
        return Self{
            .r = r,
            .g = g,
            .b = b,
            .a = 1.0,
        };
    }

    pub fn initRgba(r: f32, g: f32, b: f32, a: f32) Self {
        return Self{
            .r = r,
            .g = g,
            .b = b,
            .a = a,
        };
    }

    pub fn fromU32Rgba(value: u32) Self {
        return Self{
            .r = toF32Color(@truncate(u8, value >> 24)),
            .g = toF32Color(@truncate(u8, value >> 16)),
            .b = toF32Color(@truncate(u8, value >> 8)),
            .a = toF32Color(@truncate(u8, value)),
        };
    }

    pub fn premultipliedAlpha(this: Self) Self {
        return Self{
            .r = this.r * this.a,
            .g = this.g * this.a,
            .b = this.b * this.a,
            .a = this.a,
        };
    }

    pub fn toRgba32(this: Self) Rgba32 {
        return Rgba32{
            .r = toIntColor(u8, this.r),
            .g = toIntColor(u8, this.g),
            .b = toIntColor(u8, this.b),
            .a = toIntColor(u8, this.a),
        };
    }

    pub fn toRgba64(this: Self) Rgba64 {
        return Rgba64{
            .r = toIntColor(u16, this.r),
            .g = toIntColor(u16, this.g),
            .b = toIntColor(u16, this.b),
            .a = toIntColor(u16, this.a),
        };
    }
};

fn RgbColor(comptime ComponentType: type) type {
    return packed struct {
        r: ComponentType,
        g: ComponentType,
        b: ComponentType,

        const compBits = @typeInfo(ComponentType).Int.bits;
        const UintType = std.meta.Int(.unsigned, compBits * 3);
        const wholeByteBits = math.max(compBits, 8);
        const WholeByteType = std.meta.Int(.unsigned, wholeByteBits);

        const Self = @This();

        pub fn initRgb(r: ComponentType, g: ComponentType, b: ComponentType) Self {
            return Self{
                .r = r,
                .g = g,
                .b = b,
            };
        }

        pub inline fn getValue(this: Self) UintType {
            return @as(UintType, this.r) << (compBits * 2) |
                @as(UintType, this.g) << compBits |
                @as(UintType, this.b);
        }

        pub inline fn fromValue(value: UintType) Self {
            return Self{
                .r = @truncate(ComponentType, value >> (compBits * 2)),
                .g = @truncate(ComponentType, value >> compBits),
                .b = @truncate(ComponentType, value),
            };
        }

        pub fn toColorf32(this: Self) Colorf32 {
            return Colorf32{
                .r = toF32Color(this.r),
                .g = toF32Color(this.g),
                .b = toF32Color(this.b),
                .a = 1.0,
            };
        }
    };
}

pub const Rgb565 = packed struct {
    r: u5,
    g: u6,
    b: u5,

    const Self = @This();

    pub fn initRgb(r: u5, g: u6, b: u5) Self {
        return Self{
            .r = r,
            .g = g,
            .b = b,
        };
    }

    pub fn toColorf32(this: Self) Colorf32 {
        return Colorf32{
            .r = toF32Color(this.r),
            .g = toF32Color(this.g),
            .b = toF32Color(this.b),
            .a = 1.0,
        };
    }
};

fn RgbaColor(comptime ComponentType: type) type {
    return packed struct {
        r: ComponentType,
        g: ComponentType,
        b: ComponentType,
        a: ComponentType,

        const compBits = @typeInfo(ComponentType).Int.bits;
        const UintType = std.meta.Int(.unsigned, compBits * 4);

        const Self = @This();

        pub fn initRgb(r: ComponentType, g: ComponentType, b: ComponentType) Self {
            return Self{
                .r = r,
                .g = g,
                .b = b,
                .a = math.maxInt(ComponentType),
            };
        }

        pub fn initRgba(r: ComponentType, g: ComponentType, b: ComponentType, a: ComponentType) Self {
            return Self{
                .r = r,
                .g = g,
                .b = b,
                .a = a,
            };
        }

        pub inline fn getValue(this: Self) UintType {
            return @as(UintType, this.r) << (compBits * 3) |
                @as(UintType, this.g) << (compBits * 2) |
                @as(UintType, this.b) << compBits |
                @as(UintType, this.a);
        }

        pub inline fn fromValue(value: UintType) Self {
            return Self{
                .r = @truncate(ComponentType, value >> (compBits * 3)),
                .g = @truncate(ComponentType, value >> (compBits * 2)),
                .b = @truncate(ComponentType, value >> compBits),
                .a = @truncate(ComponentType, value),
            };
        }

        pub fn toColorf32(this: Self) Colorf32 {
            return Colorf32{
                .r = toF32Color(this.r),
                .g = toF32Color(this.g),
                .b = toF32Color(this.b),
                .a = toF32Color(this.a),
            };
        }
    };
}

// Rgb24
// OpenGL: GL_RGB
// Vulkan: VK_FORMAT_R8G8B8_UNORM
// Direct3D/DXGI: n/a
pub const Rgb24 = RgbColor(u8);

// Rgba32
// OpenGL: GL_RGBA
// Vulkan: VK_FORMAT_R8G8B8A8_UNORM
// Direct3D/DXGI: DXGI_FORMAT_R8G8B8A8_UNORM
pub const Rgba32 = RgbaColor(u8);

// Rgb555
// OpenGL: GL_RGB5
// Vulkan: VK_FORMAT_R5G6B5_UNORM_PACK16
// Direct3D/DXGI: n/a
pub const Rgb555 = RgbColor(u5);

// Rgb48
// OpenGL: GL_RGB16
// Vulkan: VK_FORMAT_R16G16B16_UNORM
// Direct3D/DXGI: n/a
pub const Rgb48 = RgbColor(u16);

// Rgba64
// OpenGL: GL_RGBA16
// Vulkan: VK_FORMAT_R16G16B16A16_UNORM
// Direct3D/DXGI: DXGI_FORMAT_R16G16B16A16_UNORM
pub const Rgba64 = RgbaColor(u16);

fn BgrColor(comptime ComponentType: type) type {
    return packed struct {
        b: ComponentType,
        g: ComponentType,
        r: ComponentType,

        const compBits = @typeInfo(ComponentType).Int.bits;
        const UintType = std.meta.Int(.unsigned, compBits * 3);

        const Self = @This();

        pub fn initRgb(r: ComponentType, g: ComponentType, b: ComponentType) Self {
            return Self{
                .r = r,
                .g = g,
                .b = b,
            };
        }

        pub inline fn getValue(this: Self) UintType {
            return @as(UintType, this.r) << (compBits * 2) |
                @as(UintType, this.g) << compBits |
                @as(UintType, this.b);
        }

        pub inline fn fromValue(value: UintType) Self {
            return Self{
                .r = @truncate(ComponentType, value >> (compBits * 2)),
                .g = @truncate(ComponentType, value >> compBits),
                .b = @truncate(ComponentType, value),
            };
        }

        pub fn toColorf32(this: Self) Colorf32 {
            return Colorf32{
                .r = toF32Color(this.r),
                .g = toF32Color(this.g),
                .b = toF32Color(this.b),
                .a = 1.0,
            };
        }
    };
}

fn BgraColor(comptime ComponentType: type) type {
    return packed struct {
        b: ComponentType,
        g: ComponentType,
        r: ComponentType,
        a: ComponentType,

        const compBits = @typeInfo(ComponentType).Int.bits;
        const UintType = std.meta.Int(.unsigned, compBits * 4);

        const Self = @This();

        pub fn initRgb(r: ComponentType, g: ComponentType, b: ComponentType) Self {
            return Self{
                .r = r,
                .g = g,
                .b = b,
                .a = math.maxInt(ComponentType),
            };
        }

        pub fn initRgba(r: ComponentType, g: ComponentType, b: ComponentType, a: ComponentType) Self {
            return Self{
                .r = r,
                .g = g,
                .b = b,
                .a = a,
            };
        }

        pub inline fn getValue(this: Self) UintType {
            return @as(UintType, this.r) << (compBits * 3) |
                @as(UintType, this.g) << (compBits * 2) |
                @as(UintType, this.b) << compBits |
                @as(UintType, this.a);
        }

        pub inline fn fromValue(value: UintType) Self {
            return Self{
                .r = @truncate(ComponentType, value >> (compBits * 3)),
                .g = @truncate(ComponentType, value >> (compBits * 2)),
                .b = @truncate(ComponentType, value >> compBits),
                .a = @truncate(ComponentType, value),
            };
        }

        pub fn toColorf32(this: Self) Colorf32 {
            return Colorf32{
                .r = toF32Color(this.r),
                .g = toF32Color(this.g),
                .b = toF32Color(this.b),
                .a = toF32Color(this.a),
            };
        }
    };
}

// Bgr24
// OpenGL: GL_BGR
// Vulkan: VK_FORMAT_B8G8R8_UNORM
// Direct3D/DXGI: n/a
pub const Bgr24 = BgrColor(u8);

// Bgra32
// OpenGL: GL_BGRA
// Vulkan: VK_FORMAT_B8G8R8A8_UNORM
// Direct3D/DXGI: DXGI_FORMAT_B8G8R8A8_UNORM
pub const Bgra32 = BgraColor(u8);

fn Grayscale(comptime ComponentType: type) type {
    return struct {
        value: ComponentType,

        const Self = @This();

        pub fn toColorf32(this: Self) Colorf32 {
            const gray = toF32Color(this.value);
            return Colorf32{
                .r = gray,
                .g = gray,
                .b = gray,
                .a = 1.0,
            };
        }
    };
}

fn GrayscaleAlpha(comptime ComponentType: type) type {
    return struct {
        value: ComponentType,
        alpha: ComponentType,

        const Self = @This();

        pub fn toColorf32(this: Self) Colorf32 {
            const gray = toF32Color(this.value);
            return Colorf32{
                .r = gray,
                .g = gray,
                .b = gray,
                .a = toF32Color(this.alpha),
            };
        }
    };
}

pub const Grayscale1 = Grayscale(u1);
pub const Grayscale2 = Grayscale(u2);
pub const Grayscale4 = Grayscale(u4);
pub const Grayscale8 = Grayscale(u8);
pub const Grayscale16 = Grayscale(u16);
pub const Grayscale8Alpha = GrayscaleAlpha(u8);
pub const Grayscale16Alpha = GrayscaleAlpha(u16);

// ********************* TESTS *********************

test "convert XYZ to xyY" {
    var actual = XYZ.init(0.5, 1, 0.5).toxyY();
    var expected = xyY.init(0.25, 0.5, 1);
    try std.testing.expect(expected.equal(actual));

    actual = XYZ.init(0, 0, 0).toxyY();
    expected = xyY.init(std_illuminant.D65.x, std_illuminant.D65.y, 0);
    try std.testing.expect(expected.equal(actual));
}

test "Illuminant names" {
    const decls = @typeInfo(std_illuminant).Struct.decls;
    const count = getStdIlluminantsCount(decls);
    try std.testing.expect(std_illuminant.names.len == count);
    inline for (std_illuminant.names) |name, i| {
        try std.testing.expect(std.mem.eql(u8, name, decls[i].name));
    }
}

test "Illuminant values" {
    const decls = @typeInfo(std_illuminant).Struct.decls;
    const count = getStdIlluminantsCount(decls);
    try std.testing.expect(std_illuminant.values.len == count);
    inline for (std_illuminant.values) |value, i| {
        try std.testing.expect(std.meta.eql(value, @field(std_illuminant, decls[i].name)));
    }
}

test "Illuminant getByName" {
    for (std_illuminant.names) |name, i| {
        var val = std_illuminant.getByName(name).?;
        try std.testing.expect(val.equal(std_illuminant.values[i]));
    }
    try std.testing.expect(std_illuminant.getByName("NA") == null);
}

test "Illuminant getName" {
    for (std_illuminant.values) |val, i| {
        var name = std_illuminant.getName(val).?;
        try std.testing.expect(std.mem.eql(u8, name, std_illuminant.names[i]));
    }
    try std.testing.expect(std_illuminant.getName(xyY.init(1, 2, 3)) == null);
}
test "Test Colorf32" {
    const tst = std.testing;
    var rgb = Colorf32.initRgb(0.2, 0.5, 0.7);
    try tst.expectEqual(@as(f32, 0.2), rgb.r);
    try tst.expectEqual(@as(f32, 0.5), rgb.g);
    try tst.expectEqual(@as(f32, 0.7), rgb.b);

    var rgba = Colorf32.initRgba(0.1, 0.4, 0.9, 0.7);
    try tst.expectEqual(@as(f32, 0.1), rgba.r);
    try tst.expectEqual(@as(f32, 0.4), rgba.g);
    try tst.expectEqual(@as(f32, 0.9), rgba.b);
    try tst.expectEqual(@as(f32, 0.7), rgba.a);

    var rgba32 = rgba.toRgba32();
    try tst.expectEqual(@as(u32, 26), rgba32.r);
    try tst.expectEqual(@as(u32, 102), rgba32.g);
    try tst.expectEqual(@as(u32, 230), rgba32.b);
    try tst.expectEqual(@as(u32, 179), rgba32.a);

    var rgba64 = rgba.toRgba64();
    try tst.expectEqual(@as(u64, 6554), rgba64.r);
    try tst.expectEqual(@as(u64, 26214), rgba64.g);
    try tst.expectEqual(@as(u64, 58982), rgba64.b);
    try tst.expectEqual(@as(u64, 45875), rgba64.a);

    rgba = rgba.premultipliedAlpha();
    try tst.expectEqual(@as(f32, 0.07), rgba.r);
    try tst.expectEqual(@as(f32, 0.28), rgba.g);
    try tst.expectEqual(@as(f32, 0.63), rgba.b);
    try tst.expectEqual(@as(f32, 0.7), rgba.a);

    rgba = Colorf32.fromU32Rgba(0x3CD174E2);
    try tst.expectEqual(@as(f32, 0.235294117647), rgba.r);
    try tst.expectEqual(@as(f32, 0.819607843137), rgba.g);
    try tst.expectEqual(@as(f32, 0.454901960784), rgba.b);
    try tst.expectEqual(@as(f32, 0.886274509804), rgba.a);
}

const TestRgbData = struct {
    init: [3]comptime_int,
    expected: [3]comptime_int,
    expectedValue: comptime_int,
    setValue: comptime_int,
    expectedAfterValue: [3]comptime_int,
    expectedColor: [4]f32,
};

test "RgbFormats" {
    const rgb555TestData = TestRgbData{
        .init = .{ 0xC, 0xF, 0x1F },
        .expected = .{ 12, 15, 31 },
        .expectedValue = 0x31FF,
        .setValue = 0x20EE,
        .expectedAfterValue = .{ 8, 7, 14 },
        .expectedColor = .{ 8 / 31.0, 7 / 31.0, 14 / 31.0, 1.0 },
    };

    try testRgbType(Rgb555, rgb555TestData);

    const rgb24TestData = TestRgbData{
        .init = .{ 0x1C, 0x7F, 0xE5 },
        .expected = .{ 0x1C, 0x7F, 0xE5 },
        .expectedValue = 0x001C7FE5,
        .setValue = 0x0090EE2A,
        .expectedAfterValue = .{ 144, 238, 42 },
        .expectedColor = .{ 144 / 255.0, 238 / 255.0, 42 / 255.0, 1.0 },
    };

    try testRgbType(Rgb24, rgb24TestData);

    const rgb48TestData = TestRgbData{
        .init = .{ 0x381C, 0xA37F, 0xE562 },
        .expected = .{ 0x381C, 0xA37F, 0xE562 },
        .expectedValue = 0x0000381CA37FE562,
        .setValue = 0x0000A27D10F56EBC,
        .expectedAfterValue = .{ 0xA27D, 0x10F5, 0x6EBC },
        .expectedColor = .{ 0xA27D / 65535.0, 0x10F5 / 65535.0, 0x6EBC / 65535.0, 1.0 },
    };

    try testRgbType(Rgb48, rgb48TestData);
}

fn testRgbType(comptime T: type, comptime testData: TestRgbData) !void {
    const tst = std.testing;
    var rgb = T.initRgb(testData.init[0], testData.init[1], testData.init[2]);
    try testRgb(rgb, @TypeOf(rgb.r), testData.expected);
    var value = rgb.getValue();
    try tst.expectEqual(@as(@TypeOf(value), testData.expectedValue), value);
    rgb = T.fromValue(testData.setValue);
    try testRgb(rgb, @TypeOf(rgb.r), testData.expectedAfterValue);

    var rgba = rgb.toColorf32();
    try testColor(rgba, f32, testData.expectedColor);
}

fn testRgb(rgb: anytype, comptime CT: type, e: [3]comptime_int) !void {
    const tst = std.testing;
    try tst.expectEqual(@as(CT, e[0]), rgb.r);
    try tst.expectEqual(@as(CT, e[1]), rgb.g);
    try tst.expectEqual(@as(CT, e[2]), rgb.b);
}

fn testColor(rgba: anytype, comptime CT: type, e: [4]CT) !void {
    const tst = std.testing;
    try tst.expectEqual(e[0], rgba.r);
    try tst.expectEqual(e[1], rgba.g);
    try tst.expectEqual(e[2], rgba.b);
    try tst.expectEqual(e[3], rgba.a);
}

const TestRgbaData = struct {
    init: [4]comptime_int,
    expected: [4]comptime_int,
    expectedValue: comptime_int,
    setValue: comptime_int,
    expectedAfterValue: [4]comptime_int,
    expectedColor: [4]f32,
};

test "RgbaFormats" {
    const rgba32TestData = TestRgbaData{
        .init = .{ 0x1C, 0x7F, 0xE5, 0xD7 },
        .expected = .{ 0x1C, 0x7F, 0xE5, 0xD7 },
        .expectedValue = 0x1C7FE5D7,
        .setValue = 0x90EE2ABB,
        .expectedAfterValue = .{ 0x90, 0xEE, 0x2A, 0xBB },
        .expectedColor = .{ 0x90 / 255.0, 0xEE / 255.0, 0x2A / 255.0, 0xBB / 255.0 },
    };

    try testRgbaType(Rgba32, rgba32TestData);

    const rgba64TestData = TestRgbaData{
        .init = .{ 0x381C, 0xA37F, 0xE562, 0xD390 },
        .expected = .{ 0x381C, 0xA37F, 0xE562, 0xD390 },
        .expectedValue = 0x381CA37FE562D390,
        .setValue = 0xA27D10F56EBCE8FA,
        .expectedAfterValue = .{ 0xA27D, 0x10F5, 0x6EBC, 0xE8FA },
        .expectedColor = .{ 0xA27D / 65535.0, 0x10F5 / 65535.0, 0x6EBC / 65535.0, 0xE8FA / 65535.0 },
    };

    try testRgbaType(Rgba64, rgba64TestData);
}

test "BgraFormats" {
    const bgra32TestData = TestRgbaData{
        .init = .{ 0x1C, 0x7F, 0xE5, 0xD7 },
        .expected = .{ 0x1C, 0x7F, 0xE5, 0xD7 },
        .expectedValue = 0x1C7FE5D7,
        .setValue = 0x90EE2ABB,
        .expectedAfterValue = .{ 0x90, 0xEE, 0x2A, 0xBB },
        .expectedColor = .{ 0x90 / 255.0, 0xEE / 255.0, 0x2A / 255.0, 0xBB / 255.0 },
    };

    try testRgbaType(Bgra32, bgra32TestData);
}

test "BgrFormats" {
    const bgr24TestData = TestRgbData{
        .init = .{ 0x1C, 0x7F, 0xE5 },
        .expected = .{ 0x1C, 0x7F, 0xE5 },
        .expectedValue = 0x001C7FE5,
        .setValue = 0x0090EE2A,
        .expectedAfterValue = .{ 144, 238, 42 },
        .expectedColor = .{ 144 / 255.0, 238 / 255.0, 42 / 255.0, 1.0 },
    };

    try testRgbType(Bgr24, bgr24TestData);
}

fn testRgbaType(comptime T: type, comptime testData: TestRgbaData) !void {
    const tst = std.testing;
    var rgb = T.initRgba(testData.init[0], testData.init[1], testData.init[2], testData.init[3]);
    try testRgba(rgb, @TypeOf(rgb.r), testData.expected);
    var value = rgb.getValue();
    try tst.expectEqual(@as(@TypeOf(value), testData.expectedValue), value);
    rgb = T.fromValue(testData.setValue);
    try testRgba(rgb, @TypeOf(rgb.r), testData.expectedAfterValue);

    var rgba = rgb.toColorf32();
    try testColor(rgba, f32, testData.expectedColor);
}

fn testRgba(rgb: anytype, comptime CT: type, e: [4]comptime_int) !void {
    const tst = std.testing;
    try tst.expectEqual(@as(CT, e[0]), rgb.r);
    try tst.expectEqual(@as(CT, e[1]), rgb.g);
    try tst.expectEqual(@as(CT, e[2]), rgb.b);
    try tst.expectEqual(@as(CT, e[3]), rgb.a);
}
