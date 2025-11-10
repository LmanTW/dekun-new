const std = @import("std");

const Respack = @This();

allocator: std.mem.Allocator,
entries: std.BufMap,

// Initialize a resource pack.
pub fn init(allocator: std.mem.Allocator) Respack {
    return .{
        .allocator = allocator,
        .entries = std.BufMap.init(allocator)
    };
}

// Deinitialize the resource pack.
pub fn deinit(self: *Respack) void {
    self.entries.deinit();
}

// Load a resource pack.
pub fn load(self: *Respack, buffer: []const u8) !void {
    var reader = std.Io.Reader.fixed(buffer); 

    for (0..try reader.takeInt(u32, .big)) |_| {
        const path_length = try reader.takeInt(u32, .big);
        const content_length = try reader.takeInt(u32, .big);

        const path_buffer = try reader.readAlloc(self.allocator, path_length);
        defer self.allocator.free(path_buffer);

        const content_buffer = try reader.readAlloc(self.allocator, content_length);
        defer self.allocator.free(content_buffer);

        try self.entries.put(path_buffer, content_buffer);
    }
}

// Save the resource pack as a base64 string.
pub fn loadBase64(self: *Respack, string: []const u8) !void {
    const buffer = try self.allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(string));
    defer self.allocator.free(buffer);

    try std.base64.standard.Decoder.decode(buffer, string);

    try self.load(buffer);
}

// Save the resource pack.
pub fn save(self: *Respack, allocator: std.mem.Allocator) ![]const u8 {
    var entry_iterator = self.entries.iterator();
    var byte_length: usize = 4;

    while (entry_iterator.next()) |entry| {
        byte_length += 4; // An u32 path length.
        byte_length += 4; // An u32 content length.
        byte_length += entry.key_ptr.len;
        byte_length += entry.value_ptr.len;
    }

    entry_iterator.index = 0;

    const buffer = try allocator.alloc(u8, byte_length);
    errdefer self.allocator.free(buffer);

    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeInt(u32, self.entries.count(), .big);

    while (entry_iterator.next()) |entry| {
        try writer.writeInt(u32, @intCast(entry.key_ptr.len), .big);
        try writer.writeInt(u32, @intCast(entry.value_ptr.len), .big);
        _ = try writer.write(entry.key_ptr.*);
        _ = try writer.write(entry.value_ptr.*);
    }

    return buffer;
}

// Save the resource pack to a base64 string.
pub fn saveBase64(self: *Respack, allocator: std.mem.Allocator) ![]const u8 {
    const buffer = try self.save(self.allocator);
    errdefer self.allocator.free(buffer);

    const size = std.base64.standard.Encoder.calcSize(buffer.len);
    const encoded = try allocator.alloc(u8, size);

    return std.base64.standard.Encoder.encode(encoded, buffer);
}

// Get an entry.
pub fn get(self: *Respack, path: []const []const u8) !?[]const u8 {
    const joined_path = try std.mem.join(self.allocator, "/", path);
    defer self.allocator.free(joined_path);

    return self.entries.get(joined_path);
}

// Set an entry.
pub fn set(self: *Respack, path: []const []const u8, content: []const u8) !void {
    const joined_path = try std.mem.join(self.allocator, "/", path);
    defer self.allocator.free(joined_path);

    try self.entries.put(joined_path, content);
}

// Read from a directory.
pub fn readDirectory(self: *Respack, directory: std.fs.Dir, path: []const []const u8) !void {
    const child_path = try self.allocator.alloc([]const u8, path.len + 1);
    defer self.allocator.free(child_path);

    var directory_iterator = directory.iterate();

    while (try directory_iterator.next()) |entry| {
        @memcpy(child_path[0..child_path.len - 1], path);
        child_path[child_path.len - 1] = entry.name;

        if (entry.kind == .file) {
            var child_file = try directory.openFile(entry.name, .{});
            defer child_file.close();

            var buffer: [1024]u8 = undefined;
            var reader = child_file.reader(&buffer);

            const content_buffer = try reader.interface.readAlloc(self.allocator, try child_file.getEndPos());
            defer self.allocator.free(content_buffer);

            try self.set(child_path, content_buffer);
        } else if (entry.kind == .directory) {
            var child_directory = try directory.openDir(entry.name, .{ .iterate = true });
            defer child_directory.close();

            try self.readDirectory(child_directory, child_path);
        }
    }
}

// Write to a directory.
pub fn writeDirectory(self: *Respack, directory: std.fs.Dir, path: []const []const u8) !void {
    const joined_path = try std.mem.join(self.allocator, "/", path);
    defer self.allocator.free(joined_path);

    var entry_iterator = self.entries.iterator();

    while (entry_iterator.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, joined_path)) {
            const parent_path = std.fs.path.dirname(entry.key_ptr.*);

            if (parent_path) |directory_path| {
                directory.access(directory_path, .{}) catch {
                    try directory.makePath(directory_path);
                };
            }

            const file = try directory.createFile(entry.key_ptr.*, .{});
            defer file.close();

            _ = try file.write(entry.value_ptr.*);
        }
    }
}
