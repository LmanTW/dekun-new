const wcwidth = @import("wcwidth");
const std = @import("std");

const utilities = @import("../utilities.zig");

const Console = @This();

allocator: std.mem.Allocator,
objects: utilities.LinkedList(Object),

stdout: *std.io.Writer,
stderr: *std.io.Writer,

working_path: []const u8,

// Initialize a console.
pub fn init(stdout: *std.io.Writer, stderr: *std.io.Writer, allocator: std.mem.Allocator) !Console {
    return .{
        .allocator = allocator,
        .objects = utilities.LinkedList(Object).init(allocator),

        .stdout = stdout,
        .stderr = stderr,

        .working_path = try std.fs.realpathAlloc(allocator, ".")
    };
}

// Deinitialize the console.
pub fn deinit(self: *Console) void {
    while (self.objects.first) |node| {
        node.data.deinit();
    }

    self.allocator.free(self.working_path);
}

// Write something to stdout.
pub fn write(self: *Console, buffer: []const u8) !void {
    _ = try self.stdout.write(buffer);

    try self.stdout.flush();
}

// Log a blank line.
pub fn blank(self: *Console) !void {
    try self.write("\n");
}

// Log a string.
pub fn log(self: *Console, string: *String) !void {
    defer string.object.deinit();

    try self.write(string.read());
}

// Log a block.
pub fn block(self: *Console, kind: Block.Kind, content: Block.Content) !void {
    const writer = if (kind == .failed) self.stderr else self.stdout;

    defer content.title.object.deinit();
    defer content.description.object.deinit();

    if (content.new_line_before) {
        try self.blank();
    } 

    try writer.print("{s}{s}\x1B[39m\n", .{kind.getTitlePrefix(), content.title.read()});

    var line_iterator = content.description.iterate();

    while (line_iterator.next()) |line| {
        try writer.print("{s}{s}\x1B[39m\n", .{kind.getDescriptionPrefix(line_iterator.peek() == null), line});
    }

    try writer.flush();

    if (content.new_line_after) {
        try self.blank();
    }
}

// Use a command.
pub fn use(self: *Console, comptime Context: type, context: *Context, command: *Command(Context)) !void {
    var arguments = utilities.SliceList(u8).init(self.allocator);
    defer arguments.deinit();

    var argument_iterator = try std.process.argsWithAllocator(self.allocator);
    defer argument_iterator.deinit();

    // Skip the executable itself.
    _ = argument_iterator.skip();

    while (argument_iterator.next()) |argument| {
        try arguments.append(argument);
    }

    var parsed_arguments = try ParsedArguments.parse(&arguments, self.allocator);
    defer parsed_arguments.deinit();

    var current_command = command;
    var positional_index: usize = 0;

    for (0..parsed_arguments.positionals.length()) |_| {
        if (current_command.getChild(parsed_arguments.positionals.get(positional_index))) |child| {
            current_command = child;
            positional_index += 1;
        } else {
            break;
        }
    }

    const positional_list = try std.mem.concat(self.allocator, []const u8, &.{&.{command.name}, parsed_arguments.positionals.array_list.items[0..positional_index]});
    defer self.allocator.free(positional_list);

    const command_name = try std.mem.join(self.allocator, " ", positional_list);
    defer self.allocator.free(command_name);

    for (0..positional_index) |_| {
        parsed_arguments.positionals.remove(0);
    }

    if (parsed_arguments.getFlag(&.{"-h", "--help"}) != null) {
        try self.blank();
        try current_command.help(command_name);
        try self.blank();
    } else {
        for (current_command.positionals.items, 0..) |positional, index| {
            if (parsed_arguments.getPositional(index)) |value| {
                var message: ?*String = null;

                switch (positional.kind) {
                    .boolean => {
                        _ = utilities.parseBoolean(value) catch {
                           message = try String.initFromBuffer(self, "The argument must be a <boolean>, which can only be \"true\" or \"false\".");
                        };
                    },

                    .integer => {
                        _ = std.fmt.parseInt(usize, value, 10) catch {
                            message = try String.initFromBuffer(self, "The argument must be an <integer>, which can be any number without a decimal point.");
                        };
                    },

                    .float => {
                        _ = std.fmt.parseFloat(f32, value) catch {
                            message = try String.initFromBuffer(self, "The argument must be a <float>, which can be any number.");
                        };
                    },

                    .file => {
                        const file_path = try std.fs.path.resolve(self.allocator, &.{self.working_path, value});
                        defer self.allocator.free(file_path);

                        if (try utilities.pathKind(null, file_path) != .file) {
                            message = try String.initFromBuffer(self, "The argument must be a <file>, which can be a relative or absolute path to the file.");
                        }
                    },

                    .directory => {
                        const directory_path = try std.fs.path.resolve(self.allocator, &.{self.working_path, value});
                        defer self.allocator.free(directory_path);

                        if (try utilities.pathKind(null, directory_path) != .directory) {
                            message = try String.initFromBuffer(self, "The argument must be a <directory>, which can be a relative or absolute path to the directory.");
                        }
                    },

                    else => {}
                }

                if (message) |string| {
                    try self.block(.failed, .{
                        .title = try String.initFromFormatted(self, "Failed to parse the argument: <{s}>", .{positional.name}),
                        .description = string,

                        .new_line_before = true,
                        .new_line_after = true
                    });

                    std.process.exit(1);
                }
            } else if (positional.required) {
                try self.block(.failed, .{
                    .title = try String.initFromFormatted(self, "Missing the argument: <{s}>", .{positional.name}),
                    .description = try String.initFromFormatted(self, "Use the \"{s} --help\" command for help.", .{command_name}),

                    .new_line_before = true,
                    .new_line_after = true
                });

                std.process.exit(1);
            }
        }

        if (parsed_arguments.countPositionals() > current_command.positionals.items.len) {
            try self.block(.failed, .{
                .title = try String.initFromFormatted(self, "Unknown {}th argument: \"{s}\"", .{current_command.positionals.items.len + 1, parsed_arguments.getPositional(current_command.positionals.items.len) orelse unreachable}),
                .description = try String.initFromFormatted(self, "Use the \"{s} --help\" command for help.", .{command_name}),

                .new_line_before = true,
                .new_line_after = true
            });

            std.process.exit(1);
        }

        for (current_command.flags.items) |flag| {
            if (parsed_arguments.getFlag(flag.names.array_list.items)) |value| {
                var message: ?*String = null;

                switch (flag.kind) {
                    .boolean => {
                        if (value.len > 0) {
                            message = try String.initFromBuffer(self, "The flag must is a <boolean> flag, which must have no value.");
                        }
                    },

                    .integer => {
                        _ = std.fmt.parseInt(usize, value, 10) catch {
                            message = try String.initFromBuffer(self, "The flag must have an <integer> value, which can be any number without a decimal point.");
                        };
                    },

                    .float => {
                        _ = std.fmt.parseFloat(f32, value) catch {
                            message = try String.initFromBuffer(self, "The flag must have a <float> value, which can be any number.");
                        };
                    },

                    .file => {
                        const file_path = try std.fs.path.resolve(self.allocator, &.{self.working_path, value});
                        defer self.allocator.free(file_path);

                        if (try utilities.pathKind(null, file_path) != .file) {
                            message = try String.initFromBuffer(self, "The flag must have a <file> value, which can be a relative or absolute path to the file.");
                        }
                    },

                    .directory => {
                        const directory_path = try std.fs.path.resolve(self.allocator, &.{self.working_path, value});
                        defer self.allocator.free(directory_path);

                        if (try utilities.pathKind(null, directory_path) != .directory) {
                            message = try String.initFromBuffer(self, "The flag must have a <directory> value, which can be a relative or absolute path to the directory.");
                        }
                    },

                    else => {}
                }

                if (message) |string| {
                    const flag_name = try flag.formatName(self.allocator);
                    defer self.allocator.free(flag_name);

                    try self.block(.failed, .{
                        .title = try String.initFromFormatted(self, "Failed to parse the flag: {s}", .{flag_name}),
                        .description = string,

                        .new_line_before = true,
                        .new_line_after = true
                    });

                    std.process.exit(1);
                }
            } else if (flag.required) {
                const flag_name = try flag.formatName(self.allocator);
                defer self.allocator.free(flag_name);

                try self.block(.failed, .{
                    .title = try String.initFromFormatted(self, "Missing the flag: {s}", .{flag_name}),
                    .description = try String.initFromFormatted(self, "Use the \"{s} --help\" command for help.", .{command_name}),

                    .new_line_before = true,
                    .new_line_after = true
                });

                std.process.exit(1);
            }
        }

        var flag_iterator = parsed_arguments.flags.iterator();

        while (flag_iterator.next()) |entry| {
            if (current_command.getFlag(entry.key_ptr.*) == null) {
                try self.block(.failed, .{
                    .title = try String.initFromFormatted(self, "Unknown flag: \"{s}\"", .{entry.key_ptr.*}),
                    .description = try String.initFromFormatted(self, "Use the \"{s} --help\" command for help.", .{command_name}),

                    .new_line_before = true,
                    .new_line_after = true
                });

                std.process.exit(1);
            }
        } 

        try current_command.callback(context, current_command, &parsed_arguments);
    } 
}

// An object.
pub const Object = struct {
    console: *Console,
    node: *utilities.LinkedList(Object).Node,
   
    length: usize,
    alignment: usize,
    unmanaged: *anyopaque,

    vtable: *const VTable,

    // The vtable of an object.
    pub const VTable = struct {
        deinit: *const fn(ptr: *anyopaque) void
    };

    // Initialize an object.
    pub fn init(console: *Console, object: anytype, vtable: *const Object.VTable) !*Object {
        const unmanaged = utilities.setReturn(@TypeOf(object), try console.allocator.create(@TypeOf(object)), object);
        errdefer console.allocator.destroy(unmanaged);

        const node = try console.objects.append(.{
            .console = console,
            .node = undefined,

            .length = @sizeOf(@TypeOf(object)),
            .alignment = @alignOf(@TypeOf(object)),
            .unmanaged = unmanaged,

            .vtable = vtable
        });

        node.data.node = node;

        return &node.data;
    }

    // Deinitialize the object.
    pub fn deinit(self: *Object) void {
        const non_const_ptr = @as([*]u8, @ptrCast(@constCast(self.unmanaged)));

        self.vtable.deinit(self.unmanaged);
        self.console.allocator.rawFree(non_const_ptr[0..self.length], .fromByteUnits(self.alignment), @returnAddress());
        self.console.objects.remove(self.node);
    }
};

// A string.
pub const String = struct {
    object: *Object,
    data: String.Data,

    // The data of the string.
    pub const Data = union(enum) {
        buffer: []const u8,
        multiline: []const *String,
        allocated: struct {
            allocator: std.mem.Allocator,
            buffer: []const u8
        },
    };

    // A line iterator.
    pub const LineIterator = union(enum) {
        buffer: std.mem.SplitIterator(u8, .scalar),
        multiline: utilities.SliceIterator(*String),
    
        // Initialize a line iterator.
        pub fn init(string: *String) String.LineIterator {
            return switch (string.data) {
                .buffer => |buffer| .{ .buffer = std.mem.splitScalar(u8, buffer, '\n') },
                .multiline => |lines| .{ .multiline = utilities.SliceIterator(*String).init(lines) },
                .allocated => |data| .{ .buffer = std.mem.splitScalar(u8, data.buffer, '\n') }
            };
        }

        // Reset the line iterator.
        pub fn reset(self: *LineIterator) void {
            switch (self.*) {
                .buffer => |*iterator| iterator.reset(),
                .multiline => |*iterator| iterator.reset()
            }
        }

        // Get the next line.
        pub fn next(self: *LineIterator) ?[]const u8 {
            switch (self.*) {
                .buffer => |*iterator| {
                    return iterator.next();
                },

                .multiline => |*iterator| {
                    if (iterator.next()) |line| {
                        return line.read();
                    }

                    return null;
                }
            }
        }

        // Peek the next line.
        pub fn peek(self: *LineIterator) ?[]const u8 {
            switch (self.*) {
                .buffer => |*iterator| {
                    return iterator.peek();
                },

                .multiline => |*iterator| {
                    if (iterator.peek()) |line| {
                        return line.read();
                    }

                    return null;
                }
            }
        }
    };

    // The vtable of a string.
    pub const VTable = Object.VTable{
        .deinit = String.deinit
    };

    // Initialize a string.
    pub fn init(console: *Console, data: String.Data) !*String {
        const object = try Object.init(console, String{
            .object = undefined,
            .data = data
        }, &String.VTable);

        const string = @as(*String, @ptrCast(@alignCast(object.unmanaged)));
        string.object = object;

        return string;
    }

    // Initialize a buffer string.
    pub fn initFromBuffer(console: *Console, buffer: []const u8) !*String {
        return try String.init(console, .{ .buffer = buffer });
    }

    // Initialize a multiline string.
    pub fn initFromMultiline(console: *Console, lines: []const *String) !*String {
        return try String.init(console, .{ .multiline = lines });
    }

    // Initialize a formatted string.
    pub fn initFromFormatted(console: *Console, comptime fmt: []const u8, args: anytype) !*String {
        const buffer = try std.fmt.allocPrint(console.allocator, fmt, args);
        errdefer console.allocator.free(buffer);

        return try String.init(console, .{
            .allocated = .{
                .allocator = console.allocator,
                .buffer = buffer
            }
        });
    }

    // Deinitialize the string.
    pub fn deinit(ptr: *anyopaque) void {
        const self = @as(*String, @ptrCast(@alignCast(ptr)));

        switch (self.data) {
            .multiline => |lines| {
                for (lines) |line| {
                    line.object.deinit();
                }
            },

            .allocated => |data| {
                data.allocator.free(data.buffer);
            },

            else => {}
        }
    }

    // Read the string.
    pub fn read(self: *String) []const u8 {
        return switch (self.data) {
            .buffer => |buffer| buffer,
            .multiline => |lines| lines[0].read(),
            .allocated => |data| data.buffer
        };
    }

    // Iterate through the string line by line.
    pub fn iterate(self: *String) String.LineIterator {
        return String.LineIterator.init(self);
    }
};

// A block.
pub const Block = struct {

    // The kind of a block.
    pub const Kind = enum {
        default,

        info,
        prepare,
        progress,

        success,
        warning,
        failed,

        // Get the prefix for the title.
        pub fn getTitlePrefix(self: Block.Kind) []const u8 {
            return switch (self) {
                .default => "  \x1B[39m",

                .info => "  \x1B[35m? ",
                .prepare => "  \x1B[32m> ",
                .progress => "  \x1B[34m* ",

                .success => "  \x1B[32m! ",
                .warning => "  \x1B[33m! ",
                .failed => "  \x1B[31m! "
            };
        }

        // Get the prefix of the description.
        pub fn getDescriptionPrefix(self: Block.Kind, last: bool) []const u8 {
            return switch (self) {
                .default => if (last) "  \x1B[90m└ \x1B[39m" else "  \x1B[90m├ \x1B[39m",

                else => if (last) "    \x1B[90m└ \x1B[39m" else "    \x1B[90m├ \x1B[39m"
            };
        }
    };

    // The content of a block.
    pub const Content = struct {
        title: *String,
        description: *String,

        new_line_before: bool,
        new_line_after: bool
    };

    // The padding of a block.
    pub const Padding = struct {
        before: bool,
        after: bool
    };
};

// A command.
pub fn Command(comptime Context: type) type {
    return struct {
        const This = @This();

        console: *Console,
        object: *Object,

        name: []const u8,
        description: []const u8,
        callback: *const fn (ctx: *Context, command: *This, parsed: *ParsedArguments) anyerror!void,

        flags: std.ArrayList(This.Flag),
        positionals: std.ArrayList(This.Positional),
        children: std.ArrayList(*This),

        // A flag.
        pub const Flag = struct {
            kind: This.Flag.Kind,
            names: utilities.SliceList(u8),
            description: []const u8,
            required: bool = false,

            // The kind of the flag.
            pub const Kind = enum {
                boolean,
                integer,
                float,
                string,

                file,
                directory
            };

            // Measure the "width" of the name of the flag.
            pub fn measureName(self: This.Flag) !usize {
                var width: usize = 0;

                for (self.names.array_list.items) |name| {
                    width += @intCast(try wcwidth.sliceWidth(name));
                }

                return width + ((self.names.array_list.items.len -% 1) * 3);
            }

            // Format the name of the flag.
            pub fn formatName(self: This.Flag, allocator: std.mem.Allocator) ![]const u8 {
               return try std.mem.join(allocator, " / ", self.names.array_list.items);
            }
        };

        // A positional.
        pub const Positional = struct {
            kind: This.Positional.Kind,
            name: []const u8,
            description: []const u8,
            required: bool = false,

            // The kind of the positional.
            pub const Kind = enum {
                boolean,
                integer,
                float,
                string,

                file,
                directory
            };

            // Measure the "width" of the name of the positional.
            pub fn measureName(self: This.Positional) !usize {
                return @as(usize, @intCast(try wcwidth.sliceWidth(self.name))) + 2;
            }

            // Format the name of the flag.
            pub fn formatName(self: This.Positional, allocator: std.mem.Allocator) ![]const u8 {
                return try std.fmt.allocPrint(allocator, "<{s}>", .{self.name});
            }
        };
        
        // The vtable of a command.
        pub const VTable = Object.VTable{
            .deinit = This.deinit
        };

        // Initialize a command.
        pub fn init(console: *Console, name: []const u8, description: []const u8, callback: *const fn (ctx: *Context, context: *This, parsed: *ParsedArguments) anyerror!void) !*This {
            const name_buffer = try console.allocator.dupe(u8, name);
            errdefer console.allocator.free(name_buffer);

            const description_buffer = try console.allocator.dupe(u8, description);
            errdefer console.allocator.free(description_buffer);

            const object = try Object.init(console, This{
                .console = console,
                .object = undefined,

                .name = name_buffer,
                .description = description_buffer,
                .callback = callback,

                .flags = std.ArrayList(This.Flag).initBuffer(&.{}),
                .positionals = std.ArrayList(This.Positional).initBuffer(&.{}),
                .children = std.ArrayList(*This).initBuffer(&.{}),
            }, &This.VTable);

            const command = @as(*This, @ptrCast(@alignCast(object.unmanaged)));
            command.object = object;

            try command.addFlag(.boolean, &.{"-h", "--help"}, "Show help information for this command.", false);

            return command;
        }
        
        // Deinitialize the command.
        pub fn deinit(ptr: *anyopaque) void {
            var self = @as(*This, @ptrCast(@alignCast(ptr)));

            self.console.allocator.free(self.name);
            self.console.allocator.free(self.description);

            for (self.flags.items) |*flag| {
                flag.names.deinit();
                self.console.allocator.free(flag.description);
            }

            for (self.positionals.items) |positional| {
                self.console.allocator.free(positional.name);
                self.console.allocator.free(positional.description);
            }

            self.flags.deinit(self.console.allocator);
            self.positionals.deinit(self.console.allocator);
            self.children.deinit(self.console.allocator);
        }

        // Get a flag.
        pub fn getFlag(self: *This, name: []const u8) ?This.Flag {
            for (self.flags.items) |*flag| {
                if (flag.names.containts(name)) {
                    return flag.*;
                } 
            }

            return null;
        }
    
        // Get a child.
        pub fn getChild(self: *This, name: []const u8) ?*This {
            for (self.children.items) |child| {
                if (std.mem.eql(u8, child.name, name)) {
                    return child;
                }
            }

            return null;
        }

        // Add a flag.
        pub fn addFlag(self: *This, kind: This.Flag.Kind, names: []const []const u8, description: []const u8, required: bool) !void {
            var name_list = utilities.SliceList(u8).init(self.console.allocator);
            errdefer name_list.deinit();

            for (names) |name| {
                if (!std.mem.startsWith(u8, name, "-"))
                    return error.InvalidFlagName;
                if (std.mem.trimStart(u8, name, "-").len == 0)
                    return error.EmptyFlagname;

                try name_list.append(name);
            }

            const description_buffer = try self.console.allocator.dupe(u8, description);
            errdefer self.console.allocator.free(description_buffer);

            try self.flags.append(self.console.allocator, .{
                .kind = kind,
                .names = name_list,
                .description = description_buffer,
                .required = required
            });
        }

        // Add a positional.
        pub fn addPositional(self: *This, kind: This.Positional.Kind, name: []const u8, description: []const u8, required: bool) !void {
            const name_buffer = try self.console.allocator.dupe(u8, name);
            errdefer self.console.allocator.free(name_buffer);

            const description_buffer = try self.console.allocator.dupe(u8, description);
            errdefer self.console.allocator.free(description_buffer);

            try self.positionals.append(self.console.allocator, .{
                .kind = kind,
                .name = name_buffer,
                .description = description_buffer,
                .required = required
            });
        }

        // Add a child.
        pub fn addChild(self: *This, command: *This) !void {
            try self.children.append(self.console.allocator, command);
        }

        // Print the help page.
        pub fn help(self: *This, name: []const u8) !void {
            var command_parts = utilities.SliceList(u8).init(self.console.allocator);
            defer command_parts.deinit();
    
            for (self.positionals.items) |positional| {
                const formatted = try std.fmt.allocPrint(self.console.allocator, " <{s}>", .{positional.name});
                errdefer self.console.allocator.free(formatted);

                try command_parts.appendOwned(formatted);
            }

            const joined_parts = try std.mem.join(self.console.allocator, "", command_parts.array_list.items);
            defer self.console.allocator.free(joined_parts);

            try self.console.block(.default, .{
                .title = try String.initFromFormatted(self.console, "Usage: {s}{s}", .{name, joined_parts}),
                .description = try String.initFromFormatted(self.console, "{s}", .{self.description}),

                .new_line_before = false,
                .new_line_after = self.positionals.items.len > 0 or self.flags.items.len > 0 or self.children.items.len > 0
            }); 

            if (self.positionals.items.len > 0) {
                var positional_name_padding: usize = 0;

                for (self.positionals.items) |positional| {
                    const width = try positional.measureName();

                    if (width > positional_name_padding) {
                        positional_name_padding = width;
                    }
                }

                var positional_names = try std.ArrayList(*String).initCapacity(self.console.allocator, self.positionals.items.len);
                defer positional_names.deinit(self.console.allocator);

                for (self.positionals.items) |positional| {
                    const positional_name = try positional.formatName(self.console.allocator);
                    defer self.console.allocator.free(positional_name);

                    try positional_names.appendBounded(try String.initFromFormatted(self.console, "{[name]s: <[padding]} | {[description]s}", .{
                        .name = positional_name,
                        .padding = positional_name_padding,
                        .description = positional.description
                    }));
                }

                try self.console.block(.default, .{
                    .title = try String.initFromBuffer(self.console, "Arguments:"),
                    .description = try String.initFromMultiline(self.console, positional_names.items),
                
                    .new_line_before = false,
                    .new_line_after = self.flags.items.len > 0
                });
            }

            if (self.flags.items.len > 0) {
                var flag_name_padding: usize = 0;

                for (self.flags.items) |flag| {
                    const width = try flag.measureName();

                    if (width > flag_name_padding) {
                        flag_name_padding = width;
                    }
                }

                var flag_lines = try std.ArrayList(*String).initCapacity(self.console.allocator, self.flags.items.len);
                defer flag_lines.deinit(self.console.allocator);

                for (self.flags.items) |flag| {
                    const flag_name = try flag.formatName(self.console.allocator);
                    defer self.console.allocator.free(flag_name);

                    try flag_lines.appendBounded(try String.initFromFormatted(self.console, "{[name]s: <[padding]} | {[description]s}", .{
                        .name = flag_name,
                        .padding = flag_name_padding,
                        .description = flag.description
                    }));
                }

                try self.console.block(.default, .{
                    .title = try String.initFromBuffer(self.console, "Flags:"),
                    .description = try String.initFromMultiline(self.console, flag_lines.items),
                
                    .new_line_before = false,
                    .new_line_after = self.children.items.len > 0
                });
            } 

            if (self.children.items.len > 0) {
                var child_name_padding: usize = 0;

                for (self.children.items) |child| {
                    const width = try wcwidth.sliceWidth(child.name);

                    if (width > child_name_padding) {
                        child_name_padding = @intCast(width);
                    }
                }

                var child_lines = try std.ArrayList(*String).initCapacity(self.console.allocator, self.children.items.len);
                defer child_lines.deinit(self.console.allocator);

                for (self.children.items) |child| {
                    try child_lines.appendBounded(try String.initFromFormatted(self.console, "{[name]s: <[padding]} | {[description]s}", .{
                        .name = child.name,
                        .padding = child_name_padding,
                        .description = child.description
                    }));
                }

                try self.console.block(.default, .{
                    .title = try String.initFromBuffer(self.console, "Subcommands:"),
                    .description = try String.initFromMultiline(self.console, child_lines.items),
                
                    .new_line_before = false,
                    .new_line_after = false
                });                
            }
        }
    };
}

// The parsed arguments.
pub const ParsedArguments = struct {
    allocator: std.mem.Allocator,

    flags: std.BufMap,
    positionals: utilities.SliceList(u8),

    // Parse the arguments.
    pub fn parse(arguments: *utilities.SliceList(u8), allocator: std.mem.Allocator) !ParsedArguments {
        var flags = std.BufMap.init(allocator);
        errdefer flags.deinit();

        var positionals = utilities.SliceList(u8).init(allocator);
        errdefer positionals.deinit();

        var argument_iterator = arguments.iterate();

        while (argument_iterator.next()) |argument| {
            if (std.mem.startsWith(u8, argument, "-")) {
                if (std.mem.indexOfScalar(u8, argument, '=')) |separator_index| {
                    try flags.put(argument[0..separator_index], argument[separator_index + 1..]);
                } else {
                    var value: []const u8 = "";

                    if (argument_iterator.peek()) |next_argument| {
                        if (!std.mem.startsWith(u8, next_argument, "-")) {
                            value = argument_iterator.next() orelse unreachable;
                        }
                    }

                    try flags.put(argument, value);
                }
            } else {
                try positionals.append(argument);
            }
        }

        return .{
            .allocator = allocator,

            .flags = flags,
            .positionals = positionals
        };
    }

    // Deinitialize the parsed arguments.
    pub fn deinit(self: *ParsedArguments) void {
        self.flags.deinit();
        self.positionals.deinit();
    }

    // Count the flags.
    pub fn countFlags(self: *ParsedArguments) u32 {
        return self.flags.count();
    }

    // Get the value of a flag.
    pub fn getFlag(self: *ParsedArguments, names: []const []const u8) ?[]const u8 {
        for (names) |name| {
            if (self.flags.get(name)) |value| {
                return value;
            }
        }

        return null;
    }

    // Get the parsed value of a flag.
    pub fn parseFlag(self: *ParsedArguments, names: []const []const u8, comptime T: type) !?T {
        if (self.getFlag(names)) |value| {
            if (!std.mem.eql(u8, value, "default")) {
                return switch (@typeInfo(T)) {
                    .bool => try utilities.parseBoolean(value),
                    .int => try std.fmt.parseInt(T, value, 10),
                    .float => try std.fmt.parseFloat(T, value, 10),

                    else => @compileError("Unsupported Type: " ++ @typeName(T))
                };
            } 
        }
    
        return null; 
    }

    // Count the positionals.
    pub fn countPositionals(self: *ParsedArguments) usize {
        return self.positionals.length();
    }

    // Get the value of a positional.
    pub fn getPositional(self: *ParsedArguments, index: usize) ?[]const u8 {
        if (index < self.positionals.length()) {
            return self.positionals.get(index);
        }

        return null;
    }

    // Get the parsed value of a positional.
    pub fn parsePositional(self: *ParsedArguments, names: []const []const u8, comptime T: type) !?T {
        if (self.getPositional(names)) |value| {
            if (!std.mem.eql(u8, value, "default")) {
                return switch (@typeInfo(T)) {
                    .bool => try utilities.parseBoolean(value),
                    .int => try std.fmt.parseInt(T, value, 10),
                    .float => try std.fmt.parseFloat(T, value, 10),

                    else => @compileError("Unsupported Type: " ++ @typeName(T))
                };
            } 
        }
    
        return null; 
    }
};
