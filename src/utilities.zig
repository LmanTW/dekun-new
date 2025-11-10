const wcwidth = @import("wcwidth");
const std = @import("std");

// A slice list.
pub fn SliceList(comptime T: type) type {
    return struct {
        const This = @This();

        allocator: std.mem.Allocator,
        array_list: std.ArrayList([]const T),

        // Initialize a slice list.
        pub fn init(allocator: std.mem.Allocator) This {
            return .{
                .allocator = allocator,
                .array_list = std.ArrayList([]const T).initBuffer(&.{})
            };
        }

        // Deinitialize the slice list.
        pub fn deinit(self: *This) void {
            for (self.array_list.items) |item| { 
                self.allocator.free(item);
            }

            self.array_list.deinit(self.allocator);
        }

        // Get the length of the slice list.
        pub fn length(self: *This) usize {
            return self.array_list.items.len;
        }

        // Check if the slice list contains a slice.
        pub fn containts(self: *This, slice: []const T) bool {
            for (self.array_list.items) |item| {
                if (std.mem.eql(T, item, slice)) {
                    return true;
                }
            }

            return false;
        }

        // Get a slice in the slice list.
        pub fn get(self: *This, index: usize) []const T {
            return self.array_list.items[index];
        }

        // Append a slice to the slice list.
        pub fn append(self: *This, slice: []const T) !void {
            const slice_buffer = try self.allocator.dupe(T, slice);
            errdefer self.allocator.free(slice_buffer);

            try self.array_list.append(self.allocator, slice_buffer);
        }
        
        // Append an already allocated slice to the slice list.
        pub fn appendOwned(self: *This, slice: []const T) !void {
            try self.array_list.append(self.allocator, slice);
        }

        // Replace a slice in the slice list.
        pub fn replace(self: *This, index: usize, slice: []const T) !void {
            const slice_buffer = try self.allocator.dupe(T, slice);
            errdefer self.allocator.free(slice_buffer);

            self.allocator.free(swapReturn([]const T, self.array_list.items[index], slice_buffer));
        }

        // Replace a slice in the slice list with an allocated slice.
        pub fn replaceOwned(self: *This, index: usize, slice: []const T) !void {
            self.allocator.free(swapReturn([]const T, self.array_list.items[index], slice));
        }

        // Remove a slice from the slice list.
        pub fn remove(self: *This, index: usize) void {
            self.allocator.free(self.array_list.orderedRemove(index));
        }
        
        // Iterate through the slice list.
        pub fn iterate(self: *This) SliceIterator([]const T) {
            return SliceIterator([]const T).init(self.array_list.items);
        }
    };
}

// A slice iterator.
pub fn SliceIterator(comptime T: type) type {
    return struct {
        const This = @This();

        items: []const T,
        index: usize,

        // Initialize a slice iterator.
        pub fn init(items: []const T) This {
            return .{
                .items = items,
                .index = 0
            };
        }

        // Reset the slice iterator.
        pub fn reset(self: *This) void {
            self.index = 0;
        }

        // Get the next item.
        pub fn next(self: *This) ?T {
            if (self.index < self.items.len) {
                return self.items[swapReturn(usize, &self.index, self.index + 1)];
            }

            return null;
        }

        // Peek the next item.
        pub fn peek(self: *This) ?T {
            if (self.index < self.items.len) {
                return self.items[self.index];
            }

            return null;
        }
    };
}

// A linked list.
pub fn LinkedList(comptime T: type) type {
    return struct {
        const This = @This();

        allocator: std.mem.Allocator,
        first: ?*This.Node,
        last: ?*This.Node,

        // An item node.
        pub const Node = struct {
            data: T,
            previous: ?*This.Node,
            next: ?*This.Node
        };

        // The linked list iterator.
        pub const Iterator = struct {
            linked_list: *This,
            current: ?*This.Node,

            // Initialize a linked list iterator.
            pub fn init(linked_list: *This) This.Iterator {
                return .{
                    .linked_list = linked_list,
                    .current = linked_list.first
                };
            }

            // Reset the linked list iterator.
            pub fn reset(self: *This.Iterator) void {
                self.current = self.linked_list.first;
            }

            // Get the next node.
            pub fn next(self: *This.Iterator) ?*This.Node {
                if (self.current) |node| {
                    return swapReturn(?*This.Node, &self.current, node.next);
                }

                return null;
            }
            
            // Peek the next node.
            pub fn peek(self: *This.Iterator) ?*This.Node {
                return self.current;
            }
        };

        // Initialize a linked list.
        pub fn init(allocator: std.mem.Allocator) This {
            return .{
                .allocator = allocator,
                .first = null,
                .last = null
            };
        }
        
        // Deinitialize the linked list.
        pub fn deinit(self: *This) void {
            var current = self.first;

            while (current) |node| {
                self.allocator.destroy(swapReturn(This.Node, &current, node.next));
            }
        }

        // Get the length of the linked list.
        pub fn length(self: *This) usize {
            var current = self.first;
            var index: usize = 0;

            while (current) |node| {
                current = node.next;
                index += 1;
            }

            return index;
        }

        // Check if the linked list contains a value.
        pub fn containts(self: *This, value: T) bool {
            var current = self.first;

            while (current) |node| {
                if (std.meta.eql(node.data, value)) {
                    return true;
                }

                current = node.next;
            }            

            return false;
        }

        // Get a node in the linked list.
        pub fn get(self: *This, index: usize) *Node {
            var current = self.first;

            for (0..index) |_| {
                if (current) |node| {
                    current = node.next;
                } else {
                    break;
                }
            }

            if (current == null) {
                @panic("Out Of Bounds Access");
            }

            return current;
        }

        // Append a node to the linked list.
        pub fn append(self: *This, item: T) !*This.Node {
            const node = setReturn(This.Node, try self.allocator.create(This.Node), .{
                .data = item,
                .previous = self.last,
                .next = null
            }); 
            
            self.last = node;

            if (self.first == null) {
                self.first = node;
            }

            if (node.previous) |previous_node| {
                previous_node.next = node;
            }

            return node;
        }

        // Replace a node in the linked list.
        pub fn replace(self: *This, index: usize, value: T) void {
            self.get(index).data = value;
        }

        // Remove a node from the slice list.
        pub fn remove(self: *This, node: *This.Node) void {
            if (self.first == node)
                self.first = node.next;
            if (self.last == node)
                self.last = node.previous; 

            if (node.previous) |previous_node|
                previous_node.next = node.next;
            if (node.next) |next_node|
                next_node.previous = node.previous;

            self.allocator.destroy(node);
        }

        // Iterate through the linked list.
        pub fn iterate(self: *This) This.Iterator {
            return This.Iterator.init(self);
        }
    };
}

// Set the value of a pointer and return the target.
pub fn setReturn(comptime T: type, target: *T, value: T) *T {
    target.* = value;

    return target;
}

// Set the value of a pointer and return the old value.
pub fn swapReturn(comptime T: type, target: *T, value: T) T {
    const old = target.*;

    target.* = value;

    return old;
}

// Parse the buffer as a boolean
pub fn parseBoolean(buffer: []const u8) !bool {
    if (std.mem.eql(u8, buffer, "true"))
        return true;
    if (std.mem.eql(u8, buffer, "false"))
        return false;

    return error.InvalidBoolean;
}

// Resolve a relative path.
pub fn resolveRelativePath(relative_path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const working_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(working_path);

    return try std.fs.path.resolve(allocator, &.{working_path, relative_path});
}

// Check the kind of a path.
pub fn pathKind(parent: ?std.fs.Dir, path: []const u8) !?std.fs.File.Kind {
    if (parent) |directory| {
        directory.access(path, .{}) catch {
            return null;
        };

        const stat = directory.statFile(path) catch |exception| {
            return if (exception == error.IsDir) .directory else null;
        };

        return stat.kind;
    }

    std.fs.accessAbsolute(path, .{}) catch {
        return null;
    };

    const stat = std.fs.cwd().statFile(path) catch |exception| {
        return if (exception == error.IsDir) .directory else null;
    };

    return stat.kind;
}

// Check if a path exists.
pub fn pathExists(parent: ?std.fs.Dir, path: []const u8) bool {
    if (parent) |directory| {
        directory.access(path, .{}) catch {
            return false;
        };

        return true;
    }

    std.fs.accessAbsolute(path, .{}) catch {
        return false;
    };

    return true;
}

// Ensure the path is a directory.
pub fn cleanDirectory(directory: std.fs.Dir) !void {
    var directory_iterator = directory.iterate();

    while (try directory_iterator.next()) |entry| {
        try directory.deleteTree(entry.name);
    }
}

// Convert a slice to a null terminated array.
pub fn toNullTerminated(comptime T: type, comptime max_length: usize, slice: []const T) ![max_length + 1:0]T {
    if (slice.len > max_length) {
        return error.SliceTooLong;
    }

    var buffer: [max_length + 1:0]T = undefined;

    buffer[slice.len] = 0;
    @memcpy(buffer[0..slice.len], slice);

    return buffer;
}
