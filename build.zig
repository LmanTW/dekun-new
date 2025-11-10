const builtin = @import("builtin");
const std = @import("std");

const Respack = @import("./src/core/Respack.zig");

const release_targets = @as([]const std.Target.Query, &.{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },

    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },

    .{ .cpu_arch = .x86_64, .os_tag = .windows },
    .{ .cpu_arch = .aarch64, .os_tag = .windows }
});

// The build info.
const BuildInfo = struct {
    version: []const u8,
    cpython: struct {
        major: usize,
        minor: usize,
        patch: usize,
        release: []const u8
    }
};

// Build the project.
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    try addRunStep(b, target);
    try addCheckStep(b, target);
    try addInstallStep(b, target);
    try addReleaseStep(b);
}

// Add the run step.
pub fn addRunStep(b: *std.Build, target: std.Build.ResolvedTarget) !void {
    const module = b.addModule("dekun", .{
        .root_source_file = b.path("./src/main.zig"),

        .target = target,
        .optimize = .Debug,

        .link_libc = true
    });

    try addDependencies(b, module);

    const exe = b.addExecutable(.{
        .name = "dekun",
        .root_module = module,

        // TODO: Remove this at zig 0.15.2
        .use_llvm = true,
    });

    const run_step = b.step("run", "Run the project");
    const run_artifact = b.addRunArtifact(exe);

    if (b.args) |args| {
        run_artifact.addArgs(args);
    }

    run_step.dependOn(&run_artifact.step);
}

// Add the check step.
pub fn addCheckStep(b: *std.Build, target: std.Build.ResolvedTarget) !void {
    const module = b.addModule("dekun", .{
        .root_source_file = b.path("./src/main.zig"),

        .target = target,
        .optimize = .Debug,

        .link_libc = true
    });

    try addDependencies(b, module);

    const exe = b.addExecutable(.{
        .name = "dekun",
        .root_module = module
    });

    b.step("check", "Check the project").dependOn(&exe.step);
}

// Add the install step.
pub fn addInstallStep(b: *std.Build, target: std.Build.ResolvedTarget) !void {
    const module = b.addModule("dekun", .{
        .root_source_file = b.path("./src/main.zig"),

        .target = target,
        .optimize = .ReleaseSafe,

        .strip = true,
        .link_libc = true
    });

    try addDependencies(b, module);

    const exe = b.addExecutable(.{
        .name = "dekun",
        .root_module = module
    });

    const install_artifact = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .prefix }
    });

    b.getInstallStep().dependOn(&install_artifact.step);
}

// Add the release step.
pub fn addReleaseStep(b: *std.Build) !void {
    const release_step = b.step("release", "Build the release executables");

    for (release_targets) |release_target| {
        const module = b.addModule("dekun", .{
            .root_source_file = b.path("./src/main.zig"),

            .target = b.resolveTargetQuery(release_target),
            .optimize = .ReleaseSafe,

            .strip = true,
            .link_libc = true
        });

        try addDependencies(b, module);

        const exe = b.addExecutable(.{
            .name = "dekun",
            .root_module = module
        });

        const os_name = @tagName(release_target.os_tag.?);
        const arch_name = switch (release_target.cpu_arch.?) {
            .x86_64 => "amd64",
            .aarch64 => "arm64",

            else => @panic("Unsupported Platform")
        };

        const release_output = b.addInstallArtifact(exe, .{
            .dest_dir = .{
                .override = .{
                    .custom = ""
                }
            },

            .dest_sub_path = switch (release_target.os_tag.?) {
                .linux, .macos => std.fmt.allocPrint(b.allocator, "dekun-{s}-{s}", .{os_name, arch_name}) catch unreachable,
                .windows => std.fmt.allocPrint(b.allocator, "dekun-{s}-{s}.exe", .{os_name, arch_name}) catch unreachable,

                else => @panic("Unsupported Platform")
            }
        });

        release_step.dependOn(&release_output.step);
    }
}

// Add the dependencies.
pub fn addDependencies(b: *std.Build, module: *std.Build.Module) !void {
    const target = module.resolved_target orelse unreachable;
    const optimize = module.optimize orelse unreachable; 

    const build_info = try std.zon.parse.fromSlice(BuildInfo, b.allocator, @constCast(@embedFile("build.zig.zon")), null, .{
        .ignore_unknown_fields = true
    });

    const source_string = try bundleSource(b.allocator);
    defer b.allocator.free(source_string);

    const buinfo = b.createModule(.{
        .root_source_file = try b.addWriteFile("buinfo.zig", b.fmt(
            \\pub const source = "{s}";
            \\pub const version = "{s}";
            \\pub const cpython = .{{
            \\    .major = {},
            \\    .minor = {},
            \\    .patch = {},
            \\    .release = "{s}"
            \\}};
        , .{source_string, build_info.version, build_info.cpython.major, build_info.cpython.minor, build_info.cpython.patch, build_info.cpython.release})).getDirectory().join(b.allocator, "buinfo.zig")
    });

    module.addImport("buinfo", buinfo);

    const wcwidth = b.dependency("wcwidth", .{
        .target = target,
        .optimize = optimize
    });

    module.addImport("wcwidth", wcwidth.module("wcwidth"));

    switch (target.result.os.tag) {
        .linux, .macos, .windows => {
            switch (target.result.cpu.arch) {
                .x86_64, .aarch64 => {
                    module.addIncludePath(b.path(b.fmt("./vendor/cpython/include/{s}-{s}", .{@tagName(target.result.cpu.arch), @tagName(target.result.os.tag)})));
                    module.addIncludePath(b.path(b.fmt("./vendor/cpython/include/{s}-{s}/cpython", .{@tagName(target.result.cpu.arch), @tagName(target.result.os.tag)})));
                    module.addIncludePath(b.path(b.fmt("./vendor/cpython/include/{s}-{s}/internal", .{@tagName(target.result.cpu.arch), @tagName(target.result.os.tag)})));
                },

                else => @panic("Unsupported Architecture")
            }
        },

        else => @panic("Unsupported Platform")
    }
}

// Bundle the source.
pub fn bundleSource(allocator: std.mem.Allocator) ![]const u8 {
    var source = Respack.init(allocator);
    defer source.deinit();

    var python_directory = try std.fs.cwd().openDir("./src/python", .{ .iterate = true });
    defer python_directory.close();

    try source.readDirectory(python_directory, &.{});

    return try source.saveBase64(allocator);
}
