pub const color = @import("src/color.zig");
pub const colorspace = @import("src/color/colorspace.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
