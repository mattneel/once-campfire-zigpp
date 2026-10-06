const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zix = b.dependency("zix", .{ .target = target, .optimize = optimize }).module("zix");
    const c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();
    const app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "zix", .module = zix }, .{ .name = "c", .module = c } },
    });
    app.linkSystemLibrary("sqlite3", .{});
    app.linkSystemLibrary("gumbo", .{});
    app.linkSystemLibrary("vips", .{});
    app.linkSystemLibrary("z", .{});
    const options = b.addOptions();
    options.addOption([]const u8, "source_root", b.root.joinString(b.allocator, "") catch @panic("out of memory"));
    app.addOptions("build_options", options);
    const exe = b.addExecutable(.{ .name = "campfire-zigpp", .root_module = app });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run native Campfire with Zig++ Threadz and Zix").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "zix", .module = zix }, .{ .name = "c", .module = c } },
    }) });
    tests.root_module.linkSystemLibrary("sqlite3", .{});
    tests.root_module.linkSystemLibrary("gumbo", .{});
    tests.root_module.linkSystemLibrary("vips", .{});
    tests.root_module.linkSystemLibrary("z", .{});
    tests.root_module.addOptions("build_options", options);
    const run_tests = b.addRunArtifact(tests);
    run_tests.addPassthruArgs();
    b.step("test", "Run native Campfire behavior and compatibility tests").dependOn(&run_tests.step);
}
