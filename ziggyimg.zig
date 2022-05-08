pub const color = @import("src/color.zig");
pub const colorspace = color.colorspace;
pub const pixel_storage = @import("src/pixel_storage.zig");
pub const ziggyio = @import("src/io.zig");
pub const png_reader = @import("src/formats/png/reader.zig");

pub fn main() !void {
    const std = @import("std");
    var timer = try std.time.Timer.start();
    defer std.debug.print("{s} took {}\n", .{@src().fn_name, std.fmt.fmtDuration(timer.read())});
    defer png_reader.printProfData();
    try png_reader.testWithDir("../ziggyimg-tests/fixtures/png/");
}

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
