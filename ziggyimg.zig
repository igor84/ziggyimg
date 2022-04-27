pub const color = @import("src/color.zig");
pub const colorspace = color.colorspace;
pub const pixel_storage = @import("src/pixel_storage.zig");
pub const ziggyio = @import("src/io.zig");
pub const pngReader = @import("src/formats/png/reader.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    var tstFile = std.fs.cwd().openFile("ShouldNotExist.img", .{}) catch null;
    if (tstFile) |file| {
        var reader = pngReader.fromFile(file);
        _ = try reader.load(std.testing.allocator, .{});
    }
}
