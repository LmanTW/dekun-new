const std = @import("std");

const utilities = @import("../utilities.zig");
const Python = @import("./Python.zig");
const Dekun = @import("./Dekun.zig");

const Bridge = @This();

python: Python,
module: Python.Object,

functions: struct {
    init_marker: Python.Object,
    load_marker: Python.Object,
    save_marker: Python.Object
},

// Initialize a bridge.
pub fn init(dekun: *Dekun, library_path: []const u8) !Bridge {
    var python = try Python.load(library_path, dekun.allocator);

    errdefer {
        python.deinit();
        python.unload();
    } 

    std.debug.print("{*}\n", .{python.binding.Py_Initialize});
    std.debug.print("{*}\n", .{python.binding.Py_InitializeFromConfig});
    std.debug.print("{*}\n", .{python.binding.Py_IncRef});
    std.debug.print("{*}\n", .{python.binding.Py_DecRef});
    std.debug.print("{*}\n", .{python.binding.Py_Finalize});
    std.debug.print("{*}\n", .{python.binding.PyConfig_InitPythonConfig});
    std.debug.print("{*}\n", .{python.binding.PyConfig_InitIsolatedConfig});
    std.debug.print("{*}\n", .{python.binding.PyConfig_Clear});
    std.debug.print("{*}\n", .{python.binding.PyConfig_SetBytesString});
    std.debug.print("{*}\n", .{python.binding.PyStatus_IsExit});
    std.debug.print("{*}\n", .{python.binding.PyStatus_IsError});
    std.debug.print("{*}\n", .{python.binding.PyModule_GetDict});
    std.debug.print("{*}\n", .{python.binding.PyDict_GetItemString});
    std.debug.print("{*}\n", .{python.binding.PyObject_CallObject});
    std.debug.print("{*}\n", .{python.binding.PyLong_FromLong});
    std.debug.print("{*}\n", .{python.binding.PyLong_AsLong});
    std.debug.print("{*}\n", .{python.binding.PyFloat_FromDouble});
    std.debug.print("{*}\n", .{python.binding.PyFloat_AsDouble});
    std.debug.print("{*}\n", .{python.binding.PyUnicode_FromString});
    std.debug.print("{*}\n", .{python.binding.PyUnicode_AsUTF8AndSize});
    std.debug.print("{*}\n", .{python.binding.PyTuple_New});
    std.debug.print("{*}\n", .{python.binding.PyTuple_GetItem});
    std.debug.print("{*}\n", .{python.binding.PyTuple_SetItem});
    std.debug.print("{*}\n", .{python.binding.PyErr_Clear});
    std.debug.print("{*}\n", .{python.binding.PyErr_Occurred});
    std.debug.print("{*}\n", .{python.binding.PyRun_SimpleString});
    std.debug.print("{*}\n", .{python.binding.PyImport_ImportModule});

    var config = try Python.Config.initIsolated(&python);
    defer config.deinit();

    const python_path = try std.fs.path.join(dekun.allocator, &.{dekun.root_path, "python"});
    defer dekun.allocator.free(python_path);

    try config.setString(&config.internal.home, python_path);
    try python.initFromConfig(config);

    const source_path = try std.fs.path.join(dekun.allocator, &.{dekun.root_path, "python", "src"});
    defer dekun.allocator.free(source_path);

    const package_path = try std.fs.path.join(dekun.allocator, &.{dekun.root_path, "packages"});
    defer dekun.allocator.free(package_path);

    const command_string = try std.fmt.allocPrint(dekun.allocator, "import sys; sys.path.insert(0, r\"{s}\"); sys.path.insert(0, r\"{s}\")", .{source_path, package_path});
    defer dekun.allocator.free(command_string);

    try python.runString(command_string);

    const module = try python.importModule("main");
    errdefer module.decreaseReference();

    const dictionary = try module.getModuleDictionary();

    return .{
        .python = python,
        .module = module,

        .functions = .{
            .init_marker = try dictionary.getDictionaryItem("init_marker"),
            .load_marker = try dictionary.getDictionaryItem("load_marker"),
            .save_marker = try dictionary.getDictionaryItem("save_marker")
        }
    };
}

// Deinitialize the bridge.
pub fn deinit(self: *Bridge) void {
    std.debug.print("Bridge Deinitialize\n", .{});

    self.module.decreaseReference();

    self.python.deinit();
    self.python.unload();
}

// Initialize a marker model.
pub fn initializeMarker(self: *Bridge, device: Dekun.State.Backend, width: usize, height: usize, depth: usize) !void {
    const arguments = try Python.Object.initTuple(&self.python, 4);
    defer arguments.decreaseReference();

    try arguments.setTupleItem(0, try Python.Object.initUnicode(&self.python, @tagName(device)));
    try arguments.setTupleItem(1, try Python.Object.initLong(&self.python, @intCast(width)));
    try arguments.setTupleItem(2, try Python.Object.initLong(&self.python, @intCast(height)));
    try arguments.setTupleItem(3, try Python.Object.initLong(&self.python, @intCast(depth)));

    const object = try self.functions.init_marker.callObject(arguments);
    defer object.decreaseReference();
}

// Save the marker model.
pub fn saveMarker(self: *Bridge, path: []const u8) !void {
    const arguments = try Python.Object.initTuple(&self.python, 1);
    defer arguments.decreaseReference();

    try arguments.setTupleItem(0, try Python.Object.initUnicode(&self.python, path));

    const object = try self.functions.save_marker.callObject(arguments);
    defer object.decreaseReference();
}
