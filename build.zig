const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const main_tests = b.addTest("ziggyimg.zig");
    main_tests.setBuildMode(mode);
    main_tests.addPackagePath("zmath", "libs/zmath.zig");
    main_tests.emit_bin = .{ .emit_to = "zig-out/ziggyimgtest"};

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
