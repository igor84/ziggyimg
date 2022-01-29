pub const color = @import("color.zig");
pub const colorspace = @import("color/colorspace.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
