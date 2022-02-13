pub const color = @import("src/color.zig");
pub const colorspace = color.colorspace;

test {
    @import("std").testing.refAllDecls(@This());
}
