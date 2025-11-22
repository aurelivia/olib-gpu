const std = @import("std");

fn dynamicAttach(b: *std.Build, wgpu: *std.Build.Dependency, comptime name: []const u8) void {
    const dll = b.addInstallLibFile(wgpu.path("lib/" ++ name), name);
    b.getInstallStep().dependOn(&dll.step);
    const lib = b.addNamedWriteFiles("lib");
    _ = lib.addCopyFile(wgpu.path("lib/" ++ name), name);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.addModule("root", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    root.link_libcpp = true;
    const collections = b.dependency("collections", .{ .target = target, .optimize = optimize });
    root.addImport("collections", collections.module("root"));

    const run_tests = b.step("test", "Run tests");
    const tests = b.createModule(.{ .root_source_file = b.path("test/root.zig"), .target = target, .optimize = optimize });
    tests.addImport("olib-gpu", root);
    const zigimg = b.dependency("zigimg", .{ .target = target, .optimize = optimize });
    tests.addImport("zigimg", zigimg.module("zigimg"));
    const test_step = b.addTest(.{ .root_module = tests, .use_llvm = true }); // use_llvm required until https://github.com/ziglang/zig/issues/25565
    run_tests.dependOn(&b.addRunArtifact(test_step).step);

    const os = @tagName(target.result.os.tag);
    const arch = @tagName(target.result.cpu.arch);
    const mode = switch (optimize) { .Debug => "debug", else => "release" };
    const abi = switch (target.result.os.tag) {
        .ios => switch (target.result.abi) {
            .simulator => "_simulator",
            else => ""
        },
        .windows => switch (target.result.abi) {
            .gnu => "_gnu",
            else => "_msvc"
        },
        else => ""
    };

    const wgpu_target = std.fmt.allocPrint(b.allocator, "wgpu_{s}_{s}{s}_{s}", .{ os, arch, abi, mode }) catch unreachable;

    for (b.available_deps) |dep| {
        if (std.mem.eql(u8, dep[0], wgpu_target)) break;
    } else std.debug.panic("No matching WGPU dependency for \"{s}\"", .{ wgpu_target });

    const link_mode = b.option(std.builtin.LinkMode, "link_mode", "Whether to link statically or dynamically.") orelse .static;

    if (b.lazyDependency(wgpu_target, .{})) |wgpu| {
        const headers = b.addTranslateC(.{ .root_source_file = wgpu.path("include/webgpu/wgpu.h"), .target = target, .optimize = optimize });
        const api = headers.addModule("wgpu");
        api.link_libcpp = true;
        root.addImport("wgpu", api);

        var path: ?std.Build.LazyPath = null;
        switch (target.result.os.tag) {
            .windows => {
                if (target.result.abi == .msvc) {
                    api.link_libcpp = false;
                    root.link_libcpp = false;
                    api.link_libc = true;
                    root.link_libc = true;

                    if (link_mode == .static) {
                        path = wgpu.path("lib/wgpu_native.lib");
                        root.linkSystemLibrary("d3dcompiler", .{});
                        root.linkSystemLibrary("user32", .{});
                        root.linkSystemLibrary("RuntimeObject", .{});
                    } else {
                        path = wgpu.path("lib/wgpu_native.dll.lib");
                    }
                } else { // .gnu
                    if (link_mode == .static) {
                        path = wgpu.path("lib/libwgpu_native.a");
                        root.linkSystemLibrary("d3dcompiler_47", .{});
                        root.linkSystemLibrary("api-ms-win-core-winrt-error-l1-1-0", .{});
                    } else {
                        path = wgpu.path("lib/libwgpu_native.dll.a");
                    }
                }

                if (link_mode == .static) {
                    root.linkSystemLibrary("opengl32", .{});
                    root.linkSystemLibrary("gdi32", .{});
                    root.linkSystemLibrary("OleAut32", .{});
                    root.linkSystemLibrary("Ole32", .{});
                    // Needed by rust stdlib for some reason
                    root.linkSystemLibrary("ws2_32", .{});
                    root.linkSystemLibrary("userenv", .{});
                    // Needed by windows-rs, dep of wgpu
                    root.linkSystemLibrary("propsys", .{});
                } else dynamicAttach(b, wgpu, "wgpu_native.dll");
            },
            .macos, .ios => {
                if (link_mode == .static) {
                    path = wgpu.path("lib/libwgpu_native.a");
                } else dynamicAttach(b, wgpu, "libwgpu_native.dylib");
            },
            else => {
                if (link_mode == .static) {
                    path = wgpu.path("lib/libwgpu_native.a");
                } else dynamicAttach(b, wgpu, "libwgpu_native.so");
            }
        }

        if (path) |p| root.addObjectFile(p);
    }
}
