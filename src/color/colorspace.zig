const zmath = @import("zmath");
const color = @import("../color.zig");
const std = @import("std");

const xyY = color.xyY;
const Mat = zmath.Mat;

/// Parameters that define an RGB color space.
pub const RGBColorSpace = struct {
    /// Color space identifier.
    id: []const u8,

    toGamma: fn (f32) f32,
    toLinear: fn (f32) f32,

    /// White point.
    white: xyY,
    /// Red point.
    red: xyY,
    /// Green point.
    green: xyY,
    /// Blue point.
    blue: xyY,

    /// RGB to XYZ conversion matrix.
    rgbToXyz: Mat,

    /// XYZ to RGB conversion matrix.
    xyzToRgb: Mat,

    const Self = @This();

    /// Construct an RGB color space from primaries and whitepoint.
    pub fn init(comptime id: []const u8, comptime gamma: anytype, white: xyY, red: xyY, green: xyY, blue: xyY) Self {
        var toGamma = dummy;
        var toLinear = dummy;
        if (@TypeOf(gamma) == comptime_float) {
            toGamma = linearToGamma(gamma);
            toLinear = gammaToLinear(gamma);
        } else if (std.mem.eql(u8, gamma, "sRGB")) {
            toGamma = linearToHybridGamma(0.0031308, 12.92, 1.055, 1 / 2.4);
            toLinear = hybridGammaToLinear(0.0031308, 12.92, 1.055, 2.4);
        } else if (std.mem.eql(u8, gamma, "Rec.601")) {
            toGamma = linearToHybridGamma(0.018, 4.5, 1.099, 0.45);
            toLinear = hybridGammaToLinear(0.018, 4.5, 1.099, 1 / 0.45);
        } else if (std.mem.eql(u8, gamma, "Rec.2020")) {
            toGamma = linearToHybridGamma(0.018053968510807, 4.5, 1.09929682680944, 0.45);
            toLinear = hybridGammaToLinear(0.018053968510807, 4.5, 1.09929682680944, 1 / 0.45);
        } else {
            @compileError("Got unsupported value for gamma parameter");
        }

        var rgbToXyz = rgbToXyzMatrix(red, green, blue, white);
        //var xyzToRgb = zmath.inverse(rgbToXyz);
        var xyzToRgb = rgbToXyz;

        var this = Self{
            .id = id,
            .toGamma = toGamma,
            .toLinear = toLinear,
            .white = white,
            .red = red,
            .green = green,
            .blue = blue,
            .rgbToXyz = rgbToXyz,
            .xyzToRgb = xyzToRgb,
        };

        return this;
    }
};

fn dummy(v: f32) f32 {
    return v;
}

fn linearToGamma(comptime gamma: comptime_float) fn (f32) f32 {
    return struct {
        fn impl(v: f32) f32 {
            return std.math.pow(f32, v, 1 / gamma);
        }
    }.impl;
}

fn linearToHybridGamma(
    comptime breakPoint: comptime_float,
    comptime linearFactor: comptime_float,
    comptime fac: comptime_float,
    comptime exp: comptime_float,
) fn (f32) f32 {
    return struct {
        fn impl(v: f32) f32 {
            if (v <= breakPoint) return v * linearFactor;
            return fac * std.math.pow(f32, v, exp) - fac + 1;
        }
    }.impl;
}

fn gammaToLinear(comptime gamma: comptime_float) fn (f32) f32 {
    return struct {
        fn impl(v: f32) f32 {
            return std.math.pow(f32, v, gamma);
        }
    }.impl;
}

fn hybridGammaToLinear(
    comptime breakPoint: comptime_float,
    comptime linearFactor: comptime_float,
    comptime fac: comptime_float,
    comptime exp: comptime_float,
) fn (f32) f32 {
    return struct {
        fn impl(v: f32) f32 {
            if (v <= breakPoint * linearFactor) return v / linearFactor;
            return std.math.pow(f32, (v + fac - 1) / fac, exp);
        }
    }.impl;
}

/// RGB to XYZ color space transformation matrix.
fn rgbToXyzMatrix(red: xyY, green: xyY, blue: xyY, white: xyY) Mat {
    var r = red.toXYZ();
    var g = green.toXYZ();
    var b = blue.toXYZ();

    // build a matrix from the 3 color vectors
    var m = Mat{
        zmath.f32x4(r.X, g.X, b.X, 0),
        zmath.f32x4(r.Y, g.Y, b.Y, 0),
        zmath.f32x4(r.Z, g.Z, b.Z, 0),
        zmath.f32x4(0, 0, 0, 1),
    };

    // multiply by the whitepoint
    var wXYZ = white.toXYZ();
    var w = zmath.f32x4(wXYZ.X, wXYZ.Y, wXYZ.Z, 1);
    //var s = zmath.mul(zmath.inverse(m), w);
    var s = zmath.mul(m, w);

    // return colorspace matrix (RGB -> XYZ)
    return .{
        m[0] * s,
        m[1] * s,
        m[2] * s,
        m[3] * s,
    };
}

const si = color.std_illuminant;

// zig fmt: off
pub const sRGB = RGBColorSpace.init("sRGB", "sRGB", si.D65, xyY.init(0.6400, 0.3300, 0.212656), xyY.init(0.3000, 0.6000, 0.715158), xyY.init(0.1500, 0.0600, 0.072186));

pub const ntsc1953     = RGBColorSpace.init("NTSC1953",  "Rec.601",   si.C, xyY.init(0.6700, 0.3300, 0.299000), xyY.init(0.2100, 0.7100, 0.587000), xyY.init(0.1400, 0.0800, 0.114000));
pub const ntsc         = RGBColorSpace.init("NTSC",      "Rec.601", si.D65, xyY.init(0.6300, 0.3400, 0.299000), xyY.init(0.3100, 0.5950, 0.587000), xyY.init(0.1550, 0.0700, 0.114000));
pub const ntsc_j       = RGBColorSpace.init("NTSC-J",    "Rec.601", si.D93, xyY.init(0.6300, 0.3400, 0.299000), xyY.init(0.3100, 0.5950, 0.587000), xyY.init(0.1550, 0.0700, 0.114000));
pub const pal_secam    = RGBColorSpace.init("PAL/SECAM", "Rec.601", si.D65, xyY.init(0.6400, 0.3300, 0.299000), xyY.init(0.2900, 0.6000, 0.587000), xyY.init(0.1500, 0.0600, 0.114000));
pub const rec709       = RGBColorSpace.init("Rec.709",   "Rec.601", si.D65, xyY.init(0.6400, 0.3300, 0.212600), xyY.init(0.3000, 0.6000, 0.715200), xyY.init(0.1500, 0.0600, 0.072200));
pub const rec2020      = RGBColorSpace.init("Rec.2020", "Rec.2020", si.D65, xyY.init(0.7080, 0.2920, 0.262700), xyY.init(0.1700, 0.7970, 0.678000), xyY.init(0.1310, 0.0460, 0.059300));

pub const adobeRGB     = RGBColorSpace.init("AdobeRGB",        2.2, si.D65, xyY.init(0.6400, 0.3300, 0.297361), xyY.init(0.2100, 0.7100, 0.627355), xyY.init(0.1500, 0.0600, 0.075285));
pub const wideGamutRGB = RGBColorSpace.init("WideGamutRGB",    2.2, si.D50, xyY.init(0.7350, 0.2650, 0.258187), xyY.init(0.1150, 0.8260, 0.724938), xyY.init(0.1570, 0.0180, 0.016875));
pub const appleRGB     = RGBColorSpace.init("AppleRGB",        1.8, si.D65, xyY.init(0.6250, 0.3400, 0.244634), xyY.init(0.2800, 0.5950, 0.672034), xyY.init(0.1550, 0.0700, 0.083332));
pub const proPhoto     = RGBColorSpace.init("ProPhoto",        1.8, si.D50, xyY.init(0.7347, 0.2653, 0.288040), xyY.init(0.1596, 0.8404, 0.711874), xyY.init(0.0366, 0.0001, 0.000086));
pub const cieRGB       = RGBColorSpace.init("CIERGB",          2.2,   si.E, xyY.init(0.7350, 0.2650, 0.176204), xyY.init(0.2740, 0.7170, 0.812985), xyY.init(0.1670, 0.0090, 0.010811));
pub const p3dci        = RGBColorSpace.init("P3DCI",           2.6, si.DCI, xyY.init(0.6800, 0.3200, 0.228975), xyY.init(0.2650, 0.6900, 0.691739), xyY.init(0.1500, 0.0600, 0.079287));
pub const p3d65        = RGBColorSpace.init("P3D65",           2.6, si.D65, xyY.init(0.6800, 0.3200, 0.228973), xyY.init(0.2650, 0.6900, 0.691752), xyY.init(0.1500, 0.0600, 0.079275));
pub const p3d60        = RGBColorSpace.init("P3D60",           2.6, si.D60, xyY.init(0.6800, 0.3200, 0.228973), xyY.init(0.2650, 0.6900, 0.691752), xyY.init(0.1500, 0.0600, 0.079275));
pub const displayP3    = RGBColorSpace.init("DisplayP3",    "sRGB", si.D65, xyY.init(0.6800, 0.3200, 0.228973), xyY.init(0.2650, 0.6900, 0.691752), xyY.init(0.1500, 0.0600, 0.079275));
// zig fmt: on

pub const rgbColorSpaces = [_]*const RGBColorSpace{
    &sRGB,
    &ntsc1953,
    &ntsc,
    &ntsc_j,
    &pal_secam,
    &rec709,
    &rec2020,
    &adobeRGB,
    &wideGamutRGB,
    &appleRGB,
    &proPhoto,
    &cieRGB,
    &p3dci,
    &p3d65,
    &p3d60,
    &displayP3,
};

pub fn getRGBColorSpaceByName(name: []const u8) ?*const RGBColorSpace {
    // Handle aliases first
    if (std.mem.eql(u8, name, "BT.709") or std.mem.eql(u8, name, "HDTV")) return &rec709;
    if (std.mem.eql(u8, name, "BT.2020") or std.mem.eql(u8, name, "UHDTV")) return &rec2020;

    for (rgbColorSpaces) |space| {
        if (std.mem.eql(u8, name, space.id)) return space;
    }

    return null;
}

pub fn getRGBColorSpaceByPoints(white: xyY, rx: f32, ry: f32, gx: f32, gy: f32, bx: f32, by: f32) ?*const RGBColorSpace {
    const math = std.math;
    const epsilon = 0.00001;
    for (rgbColorSpaces) |space| {
        if (white.approxEqual(space.white, epsilon) and
            math.approxEqAbs(f32, rx, space.red.x, epsilon) and
            math.approxEqAbs(f32, ry, space.red.y, epsilon) and
            math.approxEqAbs(f32, gx, space.green.x, epsilon) and
            math.approxEqAbs(f32, gy, space.green.y, epsilon) and
            math.approxEqAbs(f32, bx, space.blue.x, epsilon) and
            math.approxEqAbs(f32, by, space.blue.y, epsilon))
        {
            return space;
        }
    }
    return null;
}

test "sRGBToLinear" {
    const epsilon = 0.000001;
    try std.testing.expectEqual(@as(f32, 0), sRGB.toLinear(0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.000303526983548838), sRGB.toLinear(1 / 255.0), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 0.00151763491774419), sRGB.toLinear(5 / 255.0), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 0.00699541018726539), sRGB.toLinear(20 / 255.0), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0318960330730115), sRGB.toLinear(50 / 255.0), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0843762115441488), sRGB.toLinear(82 / 255.0), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 0.109461702), sRGB.toLinear(93 / 255.0), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 0.165132194501668), sRGB.toLinear(113 / 255.0), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 0.296138270798321), sRGB.toLinear(148 / 255.0), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 0.450785782838223), sRGB.toLinear(179 / 255.0), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 0.590618840919337), sRGB.toLinear(202 / 255.0), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 0.879622396887832), sRGB.toLinear(241 / 255.0), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sRGB.toLinear(255 / 255.0), epsilon);
}

test "LinearTosRGB" {
    const epsilon = 0.000001;
    try std.testing.expectEqual(@as(f32, 0), sRGB.toGamma(sRGB.toLinear(0)));
    try std.testing.expectApproxEqAbs(@as(f32, 1 / 255.0), sRGB.toGamma(sRGB.toLinear(1 / 255.0)), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 5 / 255.0), sRGB.toGamma(sRGB.toLinear(5 / 255.0)), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 20 / 255.0), sRGB.toGamma(sRGB.toLinear(20 / 255.0)), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 50 / 255.0), sRGB.toGamma(sRGB.toLinear(50 / 255.0)), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 82 / 255.0), sRGB.toGamma(sRGB.toLinear(82 / 255.0)), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 93 / 255.0), sRGB.toGamma(sRGB.toLinear(93 / 255.0)), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 113 / 255.0), sRGB.toGamma(sRGB.toLinear(113 / 255.0)), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 148 / 255.0), sRGB.toGamma(sRGB.toLinear(148 / 255.0)), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 179 / 255.0), sRGB.toGamma(sRGB.toLinear(179 / 255.0)), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 202 / 255.0), sRGB.toGamma(sRGB.toLinear(202 / 255.0)), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 241 / 255.0), sRGB.toGamma(sRGB.toLinear(241 / 255.0)), epsilon);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sRGB.toGamma(sRGB.toLinear(255 / 255.0)), epsilon);
}

test "getByName" {
    try std.testing.expectEqual(@as(?*const RGBColorSpace, null), getRGBColorSpaceByName("BT709"));
    try std.testing.expectEqual(&rec709, getRGBColorSpaceByName("BT.709").?);
    try std.testing.expectEqual(&rec709, getRGBColorSpaceByName("HDTV").?);
    try std.testing.expectEqual(&rec2020, getRGBColorSpaceByName("BT.2020").?);
    try std.testing.expectEqual(&rec2020, getRGBColorSpaceByName("UHDTV").?);
    for (rgbColorSpaces) |space| {
        try std.testing.expectEqual(space, getRGBColorSpaceByName(space.id).?);
    }
}

test "getByPoints" {
    for (rgbColorSpaces) |space| {
        var fspace = getRGBColorSpaceByPoints(space.white, space.red.x, space.red.y, space.green.x, space.green.y, space.blue.x, space.blue.y);
        if (space == &rec709) {
            // rec709 has same xy values as sRGB so it should match sRGB which has bigger priority
            try std.testing.expectEqualStrings(sRGB.id, fspace.?.id);
        } else if (space == &displayP3) {
            // displayP3 has same xy values as p3d65 with only difference in gamma so it should match p3d65 which has bigger priority
            try std.testing.expectEqualStrings(p3d65.id, fspace.?.id);
        } else {
            try std.testing.expectEqualStrings(space.id, fspace.?.id);
        }
    }
}
