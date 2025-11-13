const builtin = @import("builtin");
const buinfo = @import("buinfo");
const std = @import("std");

const utilities = @import("../utilities.zig");
const Console = @import("./Console.zig");
const Respack = @import("./Respack.zig");
const Python = @import("./Python.zig");
const Bridge = @import("./Bridge.zig");

const Dekun = @This();

console: *Console,
allocator: std.mem.Allocator,

root_path: []const u8,
root_command: *Console.Command(Dekun),

// The state.
pub const State = struct {
    dekun_version: []const u8,
    cpython_version: []const u8,

    backend: State.Backend,

    // The hardware accelartion backend.
    pub const Backend = enum {
        cpu,
        xpu,
        cuda,
        rocm,
        none,

        // Parse a slice to get the backend.
        pub fn parseSlice(slice: []const u8) ?Backend {
            if (std.mem.eql(u8, slice, "cpu"))
                return .cpu;
            if (std.mem.eql(u8, slice, "xpu"))
                return .xpu;
            if (std.mem.eql(u8, slice, "cuda"))
                return .cuda;
            if (std.mem.eql(u8, slice, "rocm"))
                return .rocm;

            return null;
        }

        // Format the backend.
        pub fn format(self: State.Backend) []const u8 {
            return switch (self) {
                .cpu => "CPU",
                .xpu => "XPU",
                .cuda => "Cuda",
                .rocm => "ROCm",
                .none => "None"
            };
        }
    };

    // Read the state from a file.
    pub fn readFromFile(file: std.fs.File, allocator: std.mem.Allocator) !std.json.Parsed(State) {
        var buffer: [1024]u8 = undefined;
        var reader = file.reader(&buffer);

        const content = try reader.interface.readAlloc(allocator, try file.getEndPos());
        defer allocator.free(content);

        return try std.json.parseFromSlice(State, allocator, content, .{
            .allocate = .alloc_always
        });
    }

    // Write the state to a file.
    pub fn writeToFile(file: std.fs.File, state: State) !void {
        var buffer: [1024]u8 = undefined;
        var writer = file.writer(&buffer);

        var stringify = std.json.Stringify{
            .writer = &writer.interface
        };

        try file.setEndPos(0);
        try stringify.write(state);
        try writer.interface.flush();
    }
};

// Initialize Dekun itself.
pub fn init(console: *Console) !Dekun {
    var environment = try std.process.getEnvMap(console.allocator);
    defer environment.deinit();

    const home_path = switch (builtin.target.os.tag) {
        .linux, .macos => environment.get("HOME"),
        .windows => environment.get("HOMEPATH"),

        else => @compileError("Unsupported Platform")
    } orelse {
        return error.HomeDirectoryNotFound;
    };

    const use_command = result: {
        const command = try Console.Command(Dekun).init(console, "use", "Use Dekun with a specific hardware accelartion backend.", use_command_callback);

        try command.addPositional(.string, "backend", "The hardware accelartion backend.", true);

        break :result command;
    };

    const root_command = result: {
        const command = try Console.Command(Dekun).init(console, "dekun", "A toolkit for marking and reconstructing parts of an image using the power of machine learning.", root_command_callback);

        try command.addFlag(.boolean, &.{"-v", "--version"}, "Get the version of Dekun.", false);
        try command.addChild(use_command);
        try command.addChild(try Marker.register(console));

        break :result command;
    };

    return .{
        .console = console,
        .allocator = console.allocator,

        .root_path = try std.fs.path.join(console.allocator, &.{home_path, ".dekun"}),
        .root_command = root_command
    };
}

// Deinitialize Dekun.
pub fn deinit(self: *Dekun) void {
    self.allocator.free(self.root_path);
}

// Ensure everything is complete.
pub fn ensureComplete(self: *Dekun, check_packages: ?State.Backend, padding: Console.Block.Padding) !State.Backend {
    try self.checkRootDirectory(padding);

    var root_directory = try std.fs.openDirAbsolute(self.root_path, .{});
    defer root_directory.close();

    var lock_file = try root_directory.openFile("lock.json", .{ .mode = .read_write });
    defer lock_file.close();

    var state = State.readFromFile(lock_file, self.allocator) catch {
        const lock_path = try std.fs.path.join(self.allocator, &.{self.root_path, "lock.json"});
        defer self.allocator.free(lock_path);

        try self.console.block(.failed, .{
            .title = try Console.String.initFromFormatted(self.console, "Corrupted lock file: {s}", .{lock_path}),
            .description = try Console.String.initFromFormatted(self.console, "Please delete the file and try again.", .{}),

            .new_line_before = !padding.after,
            .new_line_after = true
        });

        std.process.exit(1);
    };

    defer state.deinit();

    const cpython_version = try std.fmt.allocPrint(self.allocator, "{}.{}.{}", .{buinfo.cpython.major, buinfo.cpython.minor, buinfo.cpython.patch});
    defer self.allocator.free(cpython_version);

    const cpython_updated = result: {
        if (try utilities.pathKind(root_directory, "python")) |kind| {
            if (kind != .directory or !std.mem.eql(u8, cpython_version, state.value.cpython_version)) {
                try self.installPython(buinfo.cpython, .{
                    .before = !padding.after,
                    .after = padding.after
                });

                break :result true;
            }
        } else {
            try self.installPython(buinfo.cpython, .{
                .before = !padding.after,
                .after = padding.after
            });

            break :result true;
        }

        break :result false;
    };

    if (cpython_updated) {
        state.value.cpython_version = cpython_version;

        State.writeToFile(lock_file, state.value) catch {
            const lock_path = try std.fs.path.join(self.allocator, &.{self.root_path, "lock.json"});
            defer self.allocator.free(lock_path);

            try self.console.block(.failed, .{
                .title = try Console.String.initFromFormatted(self.console, "Failed to write the lock file: {s}", .{lock_path}),
                .description = try Console.String.initFromBuffer(self.console, "Please make sure Dekun have access to the directory."),

                .new_line_before = !padding.after,
                .new_line_after = true
            });

            std.process.exit(1);
        };
    }

    const source_updated = result: {
        if (!std.mem.eql(u8, state.value.dekun_version, buinfo.version)) {
            try self.installSource(.{
                .before = !padding.after,
                .after = padding.after
            });

            break :result true;
        } else if (builtin.mode == .Debug) {
            try self.installSource(.{
                .before = !padding.after,
                .after = padding.after
            });
        }

        break :result false;
    };

    if (source_updated) {
        state.value.dekun_version = buinfo.version;

        State.writeToFile(lock_file, state.value) catch {
            const lock_path = try std.fs.path.join(self.allocator, &.{self.root_path, "lock.json"});
            defer self.allocator.free(lock_path);

            try self.console.block(.failed, .{
                .title = try Console.String.initFromFormatted(self.console, "Failed to write the lock file: {s}", .{lock_path}),
                .description = try Console.String.initFromBuffer(self.console, "Please make sure Dekun have access to the directory."),

                .new_line_before = !padding.after,
                .new_line_after = true
            });

            std.process.exit(1);
        };
    }

    const packages_updated = result: {
        if (check_packages) |backend| {
            if (backend == .none) {
                try self.console.block(.warning, .{
                    .title = try Console.String.initFromBuffer(self.console, "No hardware accelartion backend is selected."),
                    .description = try Console.String.initFromBuffer(self.console, "Use the \"dekun use --help\" command for more information."),

                    .new_line_before = !padding.after,
                    .new_line_after = true
                });

                std.process.exit(1);
            } else if (backend == state.value.backend and !source_updated) {
                try self.console.block(.success, .{
                    .title = try Console.String.initFromFormatted(self.console, "Already using the backend: {s}", .{backend.format()}),
                    .description = try Console.String.initFromBuffer(self.console, "Nothing is changed because the specified backend is already installed."),

                    .new_line_before = !padding.after,
                    .new_line_after = padding.after
                });
            } else {
                try self.installPackages(backend, .{
                    .before = !padding.after,
                    .after = padding.after
                });

                break :result true;
            }
        } else {
            if (state.value.backend == .none) {
                try self.console.block(.warning, .{
                    .title = try Console.String.initFromBuffer(self.console, "No hardware accelartion backend is selected."),
                    .description = try Console.String.initFromBuffer(self.console, "Use the \"dekun use --help\" command for more information."),

                    .new_line_before = !padding.after,
                    .new_line_after = true
                });

                std.process.exit(1);
            } else {
                if (try utilities.pathKind(root_directory, "packages")) |kind| {
                    if (kind != .directory or source_updated) {
                        try self.installPackages(state.value.backend, .{
                            .before = !padding.after,
                            .after = padding.after
                        });
                    }
                } else {
                    try self.installPackages(state.value.backend, .{
                        .before = !padding.after,
                        .after = padding.after
                    });
                }
            }
        }

        break :result false;
    };

    if (packages_updated) {
        state.value.backend = check_packages orelse unreachable;

        State.writeToFile(lock_file, state.value) catch {
            const lock_path = try std.fs.path.join(self.allocator, &.{self.root_path, "lock.json"});
            defer self.allocator.free(lock_path);

            try self.console.block(.failed, .{
                .title = try Console.String.initFromFormatted(self.console, "Failed to write the lock file: {s}", .{lock_path}),
                .description = try Console.String.initFromBuffer(self.console, "Please make sure Dekun have access to the directory."),

                .new_line_before = !padding.after,
                .new_line_after = true
            });

            std.process.exit(1);
        };

        try self.console.block(.success, .{
            .title = try Console.String.initFromFormatted(self.console, "Successfully installed the backend: {s}", .{state.value.backend.format()}),
            .description = try Console.String.initFromBuffer(self.console, "You can now continue using Dekun with the specified backend."),

            .new_line_before = !padding.after,
            .new_line_after = padding.after
        });
    }

    return state.value.backend;
}

// Check the root directory.
pub fn checkRootDirectory(self: *Dekun, padding: Console.Block.Padding) !void {
    try self.console.block(.prepare, .{
        .title = try Console.String.initFromBuffer(self.console, "Checking the root directory..."),
        .description = try Console.String.initFromFormatted(self.console, "Directory: {s}", .{self.root_path}),

        .new_line_before = padding.before,
        .new_line_after = padding.after
    });

    const message = result: {
        if (try utilities.pathKind(null, self.root_path)) |kind| {
            if (kind != .directory) {
                std.fs.deleteTreeAbsolute(self.root_path) catch {
                    break :result try Console.String.initFromFormatted(self.console, "Failed to delete: {s}", .{self.root_path});
                };

                std.fs.makeDirAbsolute(self.root_path) catch {
                    break :result try Console.String.initFromFormatted(self.console, "Failed to create the root directory: {s}", .{self.root_path});
                };
            }
        } else {
            try std.fs.makeDirAbsolute(self.root_path);
        }

        var root_directory = std.fs.openDirAbsolute(self.root_path, .{}) catch {
            break :result try Console.String.initFromFormatted(self.console, "Failed to open the root directory: {s}", .{self.root_path});
        };

        defer root_directory.close();

        const lock_path = try std.fs.path.join(self.allocator, &.{self.root_path, "lock.json"});
        defer self.allocator.free(lock_path);

        const cpython_version = try std.fmt.allocPrint(self.allocator, "{}.{}.{}", .{buinfo.cpython.major, buinfo.cpython.minor, buinfo.cpython.patch});
        defer self.allocator.free(cpython_version);

        if (try utilities.pathKind(root_directory, "lock.json")) |kind| {
            if (kind != .file) {
                root_directory.deleteTree("lock.json") catch {
                    break :result try Console.String.initFromFormatted(self.console, "Failed to delete: {s}", .{self.root_path});
                };

                const lock_file = root_directory.createFile("lock.json", .{}) catch {
                    break :result try Console.String.initFromFormatted(self.console, "Failed to create the lock file: {s}", .{self.root_path});
                };

                defer lock_file.close();

                State.writeToFile(lock_file, .{
                    .dekun_version = buinfo.version,
                    .cpython_version = cpython_version,

                    .backend = .none
                }) catch {
                    break :result try Console.String.initFromFormatted(self.console, "Failed to write the lock file: {s}", .{self.root_path});
                };
            }
        } else {
            const lock_file = root_directory.createFile("lock.json", .{}) catch {
                break :result try Console.String.initFromFormatted(self.console, "Failed to open the lock file: {s}", .{self.root_path});
            };

            defer lock_file.close();

            State.writeToFile(lock_file, .{
                .dekun_version = buinfo.version,
                .cpython_version = cpython_version,

                .backend = .none
            }) catch {
                break :result try Console.String.initFromFormatted(self.console, "Failed to write the lock file: {s}", .{self.root_path});
            };
        }

        break :result null;
    };

    if (message) |string| {
        try self.console.block(.failed, .{
            .title = string,
            .description = try Console.String.initFromFormatted(self.console, "Please make sure Dekun have access to the directory.", .{}),

            .new_line_before = !padding.after,
            .new_line_after = true
        });

        std.process.exit(1);
    }
}

// Install Python.
pub fn installPython(self: *Dekun, version: @TypeOf(buinfo.cpython), padding: Console.Block.Padding) !void {
    const platform = switch (builtin.os.tag) {
        .linux => "Linux",
        .macos => "macOS",
        .windows => "Windows",

        else => @panic("Unsupported Platform")
    };

    try self.console.block(.prepare, .{
        .title = try Console.String.initFromBuffer(self.console, "Installing Python..."),
        .description = try Console.String.initFromFormatted(self.console, "Version: CPython {}.{}.{} ({s} {s})", .{version.major, version.minor, version.patch, @tagName(builtin.cpu.arch), platform}),

        .new_line_before = padding.before,
        .new_line_after = padding.after
    });

    const message = result: {
        const url = switch (builtin.os.tag) {
            .linux => try std.fmt.allocPrint(self.allocator, "https://github.com/astral-sh/python-build-standalone/releases/download/{[release]s}/cpython-{[major]}.{[minor]}.{[patch]}+{[release]s}-{[architecture]s}-unknown-linux-gnu-install_only_stripped.tar.gz", .{
                .release = buinfo.cpython.release,
                .architecture = @tagName(builtin.cpu.arch),

                .major = version.major,
                .minor = version.minor,
                .patch = version.patch
            }),

            .macos => try std.fmt.allocPrint(self.allocator, "https://github.com/astral-sh/python-build-standalone/releases/download/{[release]s}/cpython-{[major]}.{[minor]}.{[patch]}+{[release]s}-{[architecture]s}-apple-darwin-install_only_stripped.tar.gz", .{
                .release = buinfo.cpython.release,
                .architecture = @tagName(builtin.cpu.arch),

                .major = version.major,
                .minor = version.minor,
                .patch = version.patch
            }),

            .windows => try std.fmt.allocPrint(self.allocator, "https://github.com/astral-sh/python-build-standalone/releases/download/{[release]s}/cpython-{[major]}.{[minor]}.{[patch]}+{[release]s}-{[architecture]s}-pc-windows-msvc-install_only_stripped.tar.gz", .{
                .release = buinfo.cpython.release,
                .architecture = @tagName(builtin.cpu.arch),

                .major = version.major,
                .minor = version.minor,
                .patch = version.patch
            }),

            else => @panic("Unsupported Platform")
        };

        defer self.allocator.free(url);

        try self.console.block(.progress, .{
            .title = try Console.String.initFromBuffer(self.console, "Downloading the archive..."),
            .description = try Console.String.initFromFormatted(self.console, "Source: {s}", .{url}),

            .new_line_before = padding.before,
            .new_line_after = padding.after
        });

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        var response_writer = try std.Io.Writer.Allocating.initCapacity(self.allocator, 0);
        defer response_writer.deinit();

        const response = client.fetch(.{
            .method = .GET,
            .location = .{ .url = url },

            .redirect_behavior = .init(10),
            .response_writer = &response_writer.writer
        }) catch |exception| {
            try self.console.block(.failed, .{
                .title = try Console.String.initFromFormatted(self.console, "Failed to download the archive: {s}", .{@errorName(exception)}),
                .description = try Console.String.initFromBuffer(self.console, "Please make sure your have a working internet connection."),

                .new_line_before = !padding.after,
                .new_line_after = true
            });

            std.process.exit(1);
        };

        if (response.status != .ok) {
            try self.console.block(.failed, .{
                .title = try Console.String.initFromFormatted(self.console, "Failed to download the archive: {s}", .{@tagName(response.status)}),
                .description = try Console.String.initFromBuffer(self.console, "Please make sure your have a working internet connection."),

                .new_line_before = !padding.after,
                .new_line_after = true
            });

            std.process.exit(1);
        }

        const response_buffer = try response_writer.toOwnedSlice();
        defer self.allocator.free(response_buffer);

        try self.console.block(.progress, .{
            .title = try Console.String.initFromBuffer(self.console, "Extracting the archive..."),
            .description = try Console.String.initFromFormatted(self.console, "Size: {}MB ({} Bytes)", .{response_buffer.len / (1024 * 1024), response_buffer.len}),

            .new_line_before = padding.before,
            .new_line_after = padding.after
        });

        const decompress_buffer = try self.allocator.alloc(u8, std.compress.flate.max_window_len);
        defer self.allocator.free(decompress_buffer);

        var response_reader = std.Io.Reader.fixed(response_buffer);
        var decompress_reader = std.compress.flate.Decompress.init(&response_reader, .gzip, decompress_buffer);

        var root_directory = std.fs.openDirAbsolute(self.root_path, .{}) catch {
            break :result try Console.String.initFromFormatted(self.console, "Failed to open the directory: {s}", .{self.root_path});
        };

        defer root_directory.close();

        const python_path = try std.fs.path.join(self.allocator, &.{self.root_path, "python"});
        defer self.allocator.free(python_path);

        if (try utilities.pathKind(root_directory, "python")) |kind| {
            if (kind == .directory) {
                var python_directory = root_directory.openDir("python", .{ .iterate = true }) catch {
                    break :result try Console.String.initFromFormatted(self.console, "Failed to open the python directory: {s}", .{python_path});
                };
 
                defer python_directory.close();

                utilities.cleanDirectory(python_directory) catch {
                    break :result try Console.String.initFromFormatted(self.console, "Failed to clean the python directory: {s}", .{python_path});
                };
            } else {
                root_directory.deleteTree("python") catch {
                    break :result try Console.String.initFromFormatted(self.console, "Failed to delete: {s}", .{python_path});
                };

                root_directory.makeDir("python") catch {
                    break :result try Console.String.initFromFormatted(self.console, "Failed to create the python directory: {s}", .{python_path});
                };
            }
        } else {
            root_directory.makeDir("python") catch {
                break :result try Console.String.initFromFormatted(self.console, "Failed to create the python directory: {s}", .{python_path});
            };
        }

        var python_directory = try root_directory.openDir("python", .{});
        defer python_directory.close();

        std.tar.pipeToFileSystem(python_directory, &decompress_reader.reader, .{
            .strip_components = 1
        }) catch |exception| {
            break :result try Console.String.initFromFormatted(self.console, "Failed to extract the archive: {s}", .{@errorName(exception)});
        };

        const source_path = try std.fs.path.join(self.allocator, &.{self.root_path, "source"});
        defer self.allocator.free(source_path);

        if (try utilities.pathKind(python_directory, "src")) |kind| {
            if (kind == .directory) {
                var source_directory = python_directory.openDir("src", .{ .iterate = true }) catch {
                    break :result try Console.String.initFromFormatted(self.console, "Failed to open the source directory: {s}", .{source_path});
                };
 
                defer source_directory.close();

                utilities.cleanDirectory(source_directory) catch {
                    break :result try Console.String.initFromFormatted(self.console, "Failed to clean the source directory: {s}", .{source_path});
                };
            } else {
                python_directory.deleteTree("src") catch {
                    break :result try Console.String.initFromFormatted(self.console, "Failed to delete: {s}", .{source_path});
                };

                python_directory.makeDir("src") catch {
                    break :result try Console.String.initFromFormatted(self.console, "Failed to create the source directory: {s}", .{source_path});
                };
            }
        } else {
            python_directory.makeDir("src") catch {
                break :result try Console.String.initFromFormatted(self.console, "Failed to create the source directory: {s}", .{source_path});
            };
        }

        var source_directory = try python_directory.openDir("src", .{});
        defer source_directory.close();

        var source = Respack.init(self.allocator);
        defer source.deinit();

        try source.loadBase64(buinfo.source);
        try source.writeDirectory(source_directory, &.{});

        break :result null;
    };

    if (message) |string| {
        try self.console.block(.failed, .{
            .title = string,
            .description = try Console.String.initFromFormatted(self.console, "Please make sure Dekun have access to the directory.", .{}),

            .new_line_before = !padding.after,
            .new_line_after = true
        });

        std.process.exit(1);
    }
}

// Install the source.
pub fn installSource(self: *Dekun, padding: Console.Block.Padding) !void {
    try self.console.block(.prepare, .{
        .title = try Console.String.initFromBuffer(self.console, "Installing Dekun..."),
        .description = try Console.String.initFromFormatted(self.console, "Version: {s}", .{buinfo.version}),

        .new_line_before = padding.before,
        .new_line_after = padding.after
    });

    const message = result: {
        const source_path = try std.fs.path.join(self.allocator, &.{self.root_path, "python", "src"});
        defer self.allocator.free(source_path);

        if (try utilities.pathKind(null, source_path)) |kind| {
            if (kind == .directory) {
                if (builtin.mode == .Debug) {
                    var source_directory = std.fs.openDirAbsolute(source_path, .{ .iterate = true }) catch {
                        break :result try Console.String.initFromFormatted(self.console, "Failed to open the source directory: {s}", .{source_path});
                    };

                    defer source_directory.close();

                    utilities.cleanDirectory(source_directory) catch {
                        break :result try Console.String.initFromFormatted(self.console, "Failed to clean the source directory: {s}", .{source_path});
                    };
                }
            } else {
                std.fs.deleteTreeAbsolute(source_path) catch {
                    break :result try Console.String.initFromFormatted(self.console, "Failed to delete: {s}", .{source_path});
                };

                std.fs.makeDirAbsolute(source_path) catch {
                    break :result try Console.String.initFromFormatted(self.console, "Failed to create the source directory: {s}", .{source_path});
                };
            }
        } else {
            std.fs.makeDirAbsolute(source_path) catch {
                break :result try Console.String.initFromFormatted(self.console, "Failed to create the source directory: {s}", .{source_path});
            };
        }

        const size = try std.base64.standard.Decoder.calcSizeForSlice(buinfo.source);

        try self.console.block(.progress, .{
            .title = try Console.String.initFromBuffer(self.console, "Extracting the source..."),
            .description = try Console.String.initFromFormatted(self.console, "Size: {}KB ({} Bytes)", .{size / 1024, size}),

            .new_line_before = padding.before,
            .new_line_after = padding.after
        });

        var source_directory = std.fs.openDirAbsolute(source_path, .{}) catch {
            break :result try Console.String.initFromFormatted(self.console, "Failed to open the source directory: {s}", .{self.root_path});
        };

        defer source_directory.close();

        var source = Respack.init(self.allocator);
        defer source.deinit();

        try source.loadBase64(buinfo.source);

        source.writeDirectory(source_directory, &.{}) catch {
            break :result try Console.String.initFromFormatted(self.console, "Failed to extract the source: {s}", .{source_path});
        };

        break :result null;
    };

    if (message) |string| {
        try self.console.block(.failed, .{
            .title = string,
            .description = try Console.String.initFromFormatted(self.console, "Please make sure Dekun have access to the directory.", .{}),

            .new_line_before = !padding.after,
            .new_line_after = true
        });

        std.process.exit(1);
    }
}

// Install the packages.
pub fn installPackages(self: *Dekun, backend: State.Backend, padding: Console.Block.Padding) !void {
    if (builtin.os.tag == .macos and builtin.cpu.arch == .x86_64) {
        try self.console.block(.failed, .{
            .title = try Console.String.initFromBuffer(self.console, "PyTorch do not support x86_64 macOS."),
            .description = try Console.String.initFromBuffer(self.console, "Article: https://pytorch.org/blog/pytorch2-2"),

            .new_line_before = padding.before,
            .new_line_after = true
        });

        std.process.exit(1);
    } 

    const package_path = try std.fs.path.join(self.allocator, &.{self.root_path, "packages"});
    defer self.allocator.free(package_path);

    const message = result: {
        if (try utilities.pathKind(null, package_path)) |kind| {
            if (kind == .directory) {
                var package_directory = std.fs.openDirAbsolute(package_path, .{ .iterate = true }) catch {
                    break :result try Console.String.initFromFormatted(self.console, "Failed to open the package directory: {s}", .{self.root_path});
                };
 
                defer package_directory.close();

                utilities.cleanDirectory(package_directory) catch {
                    break :result try Console.String.initFromFormatted(self.console, "Failed to clean the package directory: {s}", .{self.root_path});
                };
            } else {
                std.fs.deleteTreeAbsolute(package_path) catch {
                    break :result try Console.String.initFromFormatted(self.console, "Failed to delete: {s}", .{package_path});
                };

                std.fs.makeDirAbsolute(package_path) catch {
                    break :result try Console.String.initFromFormatted(self.console, "Failed to create the package directory: {s}", .{package_path});
                };
            }
        } else {
            std.fs.makeDirAbsolute(package_path) catch {
                break :result try Console.String.initFromFormatted(self.console, "Failed to create the package directory: {s}", .{package_path});
            };            
        }

        break :result null;
    };

    if (message) |string| {
        try self.console.block(.failed, .{
            .title = string,
            .description = try Console.String.initFromFormatted(self.console, "Please make sure Dekun have access to the directory.", .{}),

            .new_line_before = !padding.after,
            .new_line_after = true
        });

        std.process.exit(1);
    }

    const packages: []const []const u8 = switch (backend) {
        .cpu => &.{
            "torch==2.9.0+cpu",
            "torchvision==0.24.0+cpu",
            "numpy==2.3.3"
        },

        .xpu => &.{
            "torch==2.9.0+xpu",
            "torchvision==0.24.0+xpu",
            "numpy==2.3.3"
        },

        .cuda => &.{
            "torch==2.9.0+cu128",
            "torchvision==0.24.0+cu128",
            "numpy==2.3.3"
        },

        .rocm => &.{
            "torch==2.9.0+rocm6.4",
            "torchvision==0.24.0+rocm6.4",
            "numpy==2.3.3"
        },

        .none => @panic("No Backend Selected"),
    };

    const index_url = switch (backend) {
        .cpu => "https://download.pytorch.org/whl/cpu",
        .xpu => "https://download.pytorch.org/whl/xpu",
        .cuda => "https://download.pytorch.org/whl/cu128",
        .rocm => "https://download.pytorch.org/whl/rocm6.4",
        .none => @panic("No Backend Selected")
    };

    const joined_packages = try std.mem.join(self.allocator, ", ", packages);
    defer self.allocator.free(joined_packages);

    try self.console.block(.prepare, .{
        .title = try Console.String.initFromBuffer(self.console, "Installing the packages..."),
        .description = try Console.String.initFromFormatted(self.console, "Packages: {s}", .{joined_packages}),

        .new_line_before = !padding.after,
        .new_line_after = padding.after
    });

    const python_path = try std.fs.path.join(self.allocator, &.{self.root_path, "python"});
    defer self.allocator.free(python_path);

    for (packages, 0..) |package, index| {
        const arguments: []const []const u8 = switch (builtin.os.tag) {
            .linux, .macos => &.{"./bin/python", "-m", "pip", "install", package, "--disable-pip-version-check", "--target",  package_path, "--index-url", index_url},
            .windows => &.{"./python.exe", "-m", "pip", "install", package, "--disable-pip-version-check", "--target", package_path, "--index-url", index_url},

            else => @panic("Unsupported Platform")
        };

        var environment = try std.process.getEnvMap(self.allocator);
        defer environment.deinit();

        try environment.put("PYTHONHOME", python_path);
        try environment.put("PYTHONPATH", package_path);

        var child = std.process.Child.init(arguments, self.allocator);

        child.cwd = python_path;
        child.env_map = &environment;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe; 

        child.spawn() catch |exception| {
            try self.console.block(.failed, .{
                .title = try Console.String.initFromFormatted(self.console, "Failed to run Pip: {s}", .{@errorName(exception)}),
                .description = try Console.String.initFromBuffer(self.console, "Please try deleting the root directory and try again."),

                .new_line_before = !padding.after,
                .new_line_after = true
            });

            std.process.exit(1);
        };

        try self.console.block(.progress, .{
            .title = try Console.String.initFromFormatted(self.console, "Installing the package: {s} ({} / {})", .{package[0..std.mem.indexOf(u8, package, "==") orelse unreachable], index + 1, packages.len}),
            .description = try Console.String.initFromFormatted(self.console, "Source: {s}/{s}", .{index_url, package[0..std.mem.indexOf(u8, package, "==") orelse unreachable]}),

            .new_line_before = !padding.after,
            .new_line_after = padding.after
        });

        var stdout = std.ArrayList(u8).initBuffer(&.{});
        var stderr = std.ArrayList(u8).initBuffer(&.{});
        defer stdout.deinit(self.allocator);
        defer stderr.deinit(self.allocator);

        try child.collectOutput(self.allocator, &stdout, &stderr, std.math.maxInt(usize));

        const result = child.wait() catch |exception| {
            try self.console.block(.failed, .{
                .title = try Console.String.initFromFormatted(self.console, "Failed to run Pip: {s}", .{@errorName(exception)}),
                .description = try Console.String.initFromBuffer(self.console, "Please try deleting the root directory and try again."),

                .new_line_before = !padding.after,
                .new_line_after = true
            });

            std.process.exit(1);
        };

        switch (result) {
            .Exited => |status_code| {
                if (status_code > 0) {
                    try self.console.block(.failed, .{
                        .title = try Console.String.initFromFormatted(self.console, "Pip exited with status code: {}", .{status_code}),
                        .description = try Console.String.initFromBuffer(self.console, std.mem.trim(u8, stderr.items, "\n ")),

                        .new_line_before = !padding.after,
                        .new_line_after = true
                    });

                    std.process.exit(1);
                }
            },

            else => {}
        }
    }
}

// Load the python bridge.
pub fn loadPythonBridge(self: *Dekun, padding: Console.Block.Padding) !Bridge {
    try self.console.block(.prepare, .{
        .title = try Console.String.initFromBuffer(self.console, "Loading the Python runtime..."),
        .description = try Console.String.initFromFormatted(self.console, "CPython: {}.{}.{}", .{buinfo.cpython.major, buinfo.cpython.minor, buinfo.cpython.patch}),

        .new_line_before = padding.before,
        .new_line_after = padding.after
    });

    const library_path = result: {
        switch (builtin.os.tag) {
            .linux => {
                const name = try std.fmt.allocPrint(self.allocator, "libpython{}.{}.so.1.0", .{buinfo.cpython.major, buinfo.cpython.minor});
                defer self.allocator.free(name);

                break :result try std.fs.path.join(self.allocator, &.{self.root_path, "python-debug", "lib", name});
            },

            .macos => {
                const name = try std.fmt.allocPrint(self.allocator, "libpython{}.{}.dylib", .{buinfo.cpython.major, buinfo.cpython.minor});
                defer self.allocator.free(name);

                break :result try std.fs.path.join(self.allocator, &.{self.root_path, "python", "lib", name});
            },

            .windows => {
                const name = try std.fmt.allocPrint(self.allocator, "python{}{}.dll", .{buinfo.cpython.major, buinfo.cpython.minor});
                defer self.allocator.free(name);

                break :result try std.fs.path.join(self.allocator, &.{self.root_path, "python", name});
            },

            else => @panic("Unsupported Platform")
        }
    };

    defer self.allocator.free(library_path);

    return try Bridge.init(self, library_path);
}

// The callback for the root command.
fn root_command_callback(self: *Dekun, command: *Console.Command(Dekun), parsed: *Console.ParsedArguments) !void {
    if (parsed.getFlag(&.{"-v", "--version"}) == null) {
        try self.console.blank();
        try command.help("dekun");
        try self.console.blank();
    } else {
        const platform = switch (builtin.os.tag) {
            .linux => "Linux",
            .macos => "macOS",
            .windows => "Windows",

            else => @panic("Unsupported Platform")
        };

        try self.console.block(.default, .{
            .title = try Console.String.initFromFormatted(self.console, "Dekun {s} ({s} {s})", .{buinfo.version, @tagName(builtin.cpu.arch), platform}),
            .description = try Console.String.initFromFormatted(self.console, "Built with Zig {s} ({s})", .{builtin.zig_version_string, @tagName(builtin.mode)}),
            
            .new_line_before = true,
            .new_line_after = true
        });
    }
}

// The callback for the use command.
fn use_command_callback(self: *Dekun, _: *Console.Command(Dekun), parsed: *Console.ParsedArguments) !void {
    if (State.Backend.parseSlice(parsed.getPositional(0) orelse unreachable)) |backend| {
        _ = try self.ensureComplete(backend, .{
            .before = true,
            .after = true
        });
    } else {
        try self.console.block(.failed, .{
            .title = try Console.String.initFromFormatted(self.console, "Unsupported backend: \"{s}\"", .{parsed.getPositional(0) orelse unreachable}),
            .description = try Console.String.initFromBuffer(self.console, "Avialiable backends: cpu, xpu, cuda, rocm"),

            .new_line_before = true,
            .new_line_after = true
        });

        std.process.exit(1);
    } 
}

// The marker.
pub const Marker = struct {

    // Regiter the marker command.
    pub fn register(console: *Console) !*Console.Command(Dekun) {
         const init_command = result: {
            const command = try Console.Command(Dekun).init(console, "init", "Initialize a marker model.", Marker.init_command_callback);

            try command.addFlag(.integer, &.{"-w", "--width"}, "The maximum input width of the model.", false);
            try command.addFlag(.integer, &.{"-h", "--height"}, "The maximum input height of the model.", false);
            try command.addFlag(.integer, &.{"-d", "--depth"}, "The depth of the internal U-Net model.", false);
            try command.addPositional(.string, "path", "The path to where the marker model file should be created.", true);

            break :result command;
        };

         const info_command = result: {
            const command = try Console.Command(Dekun).init(console, "info", "Get the info of a marker model.", Marker.info_command_callback);

            try command.addPositional(.string, "path", "The path to where the marker model file.", true);

            break :result command;
        };

         const mark_command = result: {
            const command = try Console.Command(Dekun).init(console, "mark", "Mark an image using a marker model.", Marker.mark_command_callback);

            try command.addFlag(.file, &.{"-i", "--input"}, "The path to the input image file.", true);
            try command.addFlag(.file, &.{"-o", "--output"}, "The path to where the output image file should be created.", false);
            try command.addPositional(.string, "path", "The path to the marker model file.", true);

            break :result command;
        };

         const train_command = result: {
            const command = try Console.Command(Dekun).init(console, "train", "Train a marker model using a dataset.", Marker.train_command_callback);

            try command.addFlag(.directory, &.{"-d", "--dataset"}, "The path to the dataset directory.", true);
            try command.addFlag(.integer, &.{"-i", "--iterations"}, "The total iterations to train the model.", false);
            try command.addFlag(.integer, &.{"-c", "--checkpoint"}, "The number iterations to create a checkpoint.", false);
            try command.addPositional(.string, "path", "The path to the marker model file.", true);

            break :result command;
        };

         const marker_command = result: {
             const command = try Console.Command(Dekun).init(console, "marker", "Utility for the marker model which marks the input image and output a mask. ", Marker.marker_command_callback);

             try command.addChild(init_command);
             try command.addChild(info_command);
             try command.addChild(mark_command);
             try command.addChild(train_command);

             break :result command;
         };

         return marker_command;
    }

    // The callback for the marker command.
    fn marker_command_callback(self: *Dekun,  command: *Console.Command(Dekun), _: *Console.ParsedArguments) !void {
        try self.console.blank();
        try command.help("dekun marker");
        try self.console.blank();
    }

    // The callback for the init command.
    fn init_command_callback(self: *Dekun,  _: *Console.Command(Dekun), parsed: *Console.ParsedArguments) !void {
        const backend = try self.ensureComplete(null, .{
            .before = true,
            .after = true
        });

        var bridge = try self.loadPythonBridge(.{
            .before = false,
            .after = true
        });

        defer bridge.deinit();

        const width = try parsed.parseFlag(&.{"-w", "--width"}, usize) orelse 512;
        const height = try parsed.parseFlag(&.{"-h", "--height"}, usize) orelse 512;
        const depth = try parsed.parseFlag(&.{"-d", "--depth"}, usize) orelse 5;

        try self.console.block(.prepare, .{
            .title = try Console.String.initFromBuffer(self.console, "Initializing a marker model..."),
            .description = try Console.String.initFromMultiline(self.console, &.{
                try Console.String.initFromFormatted(self.console, "Width: {}", .{width}),
                try Console.String.initFromFormatted(self.console, "Height: {}", .{height}),
                try Console.String.initFromFormatted(self.console, "Depth: {}", .{depth})
            }),

            .new_line_before = false,
            .new_line_after = true
        });

        try bridge.initializeMarker(backend, width, height, depth);

        var model_path = try utilities.resolveRelativePath(parsed.getPositional(0) orelse unreachable, self.allocator);
        defer self.allocator.free(model_path);

        if (!std.mem.endsWith(u8, model_path, ".pth")) {
            self.allocator.free(utilities.swapReturn([]const u8, &model_path, try std.fmt.allocPrint(self.allocator, "{s}.pth", .{model_path})));
        }

        try self.console.block(.progress, .{
            .title = try Console.String.initFromBuffer(self.console, "Saving the marker model..."),
            .description = try Console.String.initFromFormatted(self.console, "Path: {s}", .{model_path}),

            .new_line_before = false,
            .new_line_after = true
        });

        try bridge.saveMarker(model_path);
    }

    // The callback for the info command.
    fn info_command_callback(_: *Dekun,  _: *Console.Command(Dekun), _: *Console.ParsedArguments) !void {

    }

    // The callback for the mark command.
    fn mark_command_callback(_: *Dekun,  _: *Console.Command(Dekun), _: *Console.ParsedArguments) !void {

    }

    // The callback for the train command.
    fn train_command_callback(_: *Dekun,  _: *Console.Command(Dekun), _: *Console.ParsedArguments) !void {

    }
};
