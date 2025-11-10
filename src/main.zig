const std = @import("std");

const Console = @import("./core/Console.zig");
const utilities = @import("./utilities.zig");
const Python = @import("./core/Python.zig");
const Dekun = @import("./core/Dekun.zig");

// The main function :3
pub fn main() !void {
    var debug = std.heap.DebugAllocator(.{}).init;
    defer _ = debug.deinit();

    // Yes sir, the allocator.
    const allocator = debug.allocator();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);

    var console = try Console.init(&stdout_writer.interface, &stderr_writer.interface, allocator);
    defer console.deinit();

    var dekun = try Dekun.init(&console);
    defer dekun.deinit();

    try console.use(Dekun, &dekun, dekun.root_command);
}
