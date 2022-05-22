pub const color = @import("src/color.zig");
pub const colorspace = color.colorspace;
pub const pixel_storage = @import("src/pixel_storage.zig");
pub const ziggyio = @import("src/io.zig");
pub const png_reader = @import("src/formats/png/reader.zig");
const InfoProcessor = @import("src/formats/png/InfoProcessor.zig");
const std = @import("std");

// This overrides the default PngOptions
pub const DefPngOptions = InfoProcessor.PngInfoOptions;

pub fn main() !void {
    var timer = try std.time.Timer.start();
    defer std.debug.print("{s} took {}\n", .{@src().fn_name, std.fmt.fmtDuration(timer.read())});
    defer png_reader.printProfData();
    try png_reader.testWithDir("../ziggyimg-tests/fixtures/png/", false);
}

test {
    std.testing.refAllDecls(@This());
}
