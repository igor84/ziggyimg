const std = @import("std");

// This implements [CIE XYZ](https://en.wikipedia.org/wiki/CIE_1931_color_space)
// color types. These color spaces represent the simplest expression of the
// full-spectrum of human visible color. No attempts are made to support
// perceptual uniformity, or meaningful color blending within these color
// spaces. They are most useful as an absolute representation of human visible
// colors, and a centre point for color space conversions.
pub const XYZ = struct {
    X: f32,
    Y: f32,
    Z: f32,

    pub fn init(x: f32, y: f32, z: f32) XYZ {
        return XYZ {.X = x, .Y = y, .Z = z};
    }

    pub fn toxyY(self: XYZ) xyY {
        var sum = self.X + self.Y + self.Z;
        if (sum != 0) return xyY.init(self.X / sum, self.Y / sum, self.Y);

        return xyY.init(std_illuminant.D65.x, std_illuminant.D65.y, 0);
    }

    pub inline fn equal(self: xyY, other: xyY) bool {
        return self.Y == other.Y and self.X == other.X and self.Z == other.Z;
    }

    pub inline fn approxEqual(self: xyY, other: xyY) bool {
        const math = std.math;
        return math.approxEqAbs(f32, self.Y, other.Y, math.f32_epsilon)
            and math.approxEqAbs(f32, self.X, other.X, math.f32_epsilon)
            and math.approxEqAbs(f32, self.Z, other.Z, math.f32_epsilon);
    }
};

// This implements [CIE XYZ](https://en.wikipedia.org/wiki/CIE_1931_color_space#CIE_xy_chromaticity_diagram_and_the_CIE_xyY_color_space)
// color types. These color spaces represent the simplest expression of the
// full-spectrum of human visible color. No attempts are made to support
// perceptual uniformity, or meaningful color blending within these color
// spaces. They are most useful as an absolute representation of human visible
// colors, and a centre point for color space conversions.
pub const xyY = struct {
    x: f32,
    y: f32,
    Y: f32,

    pub fn init(x: f32, y: f32, Y: f32) xyY {
        return xyY {.x = x, .y = y, .Y = Y};
    }

    pub fn toXYZ(self: xyY) XYZ {
        if (self.Y == 0) return XYZ.init(0, 0, 0);

        var ratio = self.Y / self.y;
        return XYZ.init(ratio * self.x, self.Y, ratio * (1 - self.x - self.y));
    }

    pub inline fn equal(self: xyY, other: xyY) bool {
        return self.Y == other.Y and self.x == other.x and self.y == other.y;
    }

    pub inline fn approxEqual(self: xyY, other: xyY) bool {
        const math = std.math;
        return math.approxEqAbs(f32, self.Y, other.Y, math.f32_epsilon)
            and math.approxEqAbs(f32, self.x, other.x, math.f32_epsilon)
            and math.approxEqAbs(f32, self.y, other.y, math.f32_epsilon);
    }
};

test "convert XYZ to xyY" {
    var actual = XYZ.init(0.5, 1, 0.5).toxyY();
    var expected = xyY.init(0.25, 0.5, 1);
    try std.testing.expect(expected.equal(actual));

    actual = XYZ.init(0, 0, 0).toxyY();
    expected = xyY.init(std_illuminant.D65.x, std_illuminant.D65.y, 0);
    try std.testing.expect(expected.equal(actual));
}

/// The illuminant values as defined on https://en.wikipedia.org/wiki/Standard_illuminant.
pub const std_illuminant = struct {
    /// Incandescent / Tungsten
    pub const A =   xyY.init(0.44757, 0.40745, 1.00000);
    /// [obsolete] Direct sunlight at noon
    pub const B =   xyY.init(0.34842, 0.35161, 1.00000);
    /// [obsolete] Average / North sky Daylight
    pub const C =   xyY.init(0.31006, 0.31616, 1.00000);
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
    pub const E =   xyY.init(1.0/3.0, 1.0/3.0, 1.00000);
    /// Daylight Fluorescent
    pub const F1 =  xyY.init(0.31310, 0.33727, 1.00000);
    /// Cool White Fluorescent
    pub const F2 =  xyY.init(0.37208, 0.37529, 1.00000);
    /// White Fluorescent
    pub const F3 =  xyY.init(0.40910, 0.39430, 1.00000);
    /// Warm White Fluorescent
    pub const F4 =  xyY.init(0.44018, 0.40329, 1.00000);
    /// Daylight Fluorescent
    pub const F5 =  xyY.init(0.31379, 0.34531, 1.00000);
    /// Lite White Fluorescent
    pub const F6 =  xyY.init(0.37790, 0.38835, 1.00000);
    /// D65 simulator, Daylight simulator
    pub const F7 =  xyY.init(0.31292, 0.32933, 1.00000);
    /// D50 simulator, Sylvania F40 Design 50
    pub const F8 =  xyY.init(0.34588, 0.35875, 1.00000);
    /// Cool White Deluxe Fluorescent
    pub const F9 =  xyY.init(0.37417, 0.37281, 1.00000);
    /// Philips TL85, Ultralume 50
    pub const F10 = xyY.init(0.34609, 0.35986, 1.00000);
    /// Philips TL84, Ultralume 40
    pub const F11 = xyY.init(0.38052, 0.37713, 1.00000);
    /// Philips TL83, Ultralume 30
    pub const F12 = xyY.init(0.43695, 0.40441, 1.00000);

    pub const values = [_]xyY{
        A, B, C, D50, D55, D60, D65, D75, D93, DCI, E,
        F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12
    };
    pub const names = [_][]const u8{
        "A", "B", "C", "D50", "D55", "D60", "D65", "D75", "D93", "DCI", "E",
        "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"
    };

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
        while (count < decls.len and switch (decls[count].data) {.Var => |t| t == xyY, else => false}) {
            count += 1;
        }
        return count;
    }
}

test "Illuminant names" {
    const decls =  @typeInfo(std_illuminant).Struct.decls;
    const count = getStdIlluminantsCount(decls);
    try std.testing.expect(std_illuminant.names.len == count);
    inline for (std_illuminant.names) |name, i| {
        try std.testing.expect(std.mem.eql(u8, name, decls[i].name));
    }
}

test "Illuminant values" {
    const decls =  @typeInfo(std_illuminant).Struct.decls;
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