const builtin = @import("builtin");
const std = @import("std");

const c = @cImport({
    @cInclude("Python.h");
});

const utilities = @import("../utilities.zig");

const Python = @This();

allocator: std.mem.Allocator,
handle: switch (builtin.os.tag) {
    .linux, .macos => *anyopaque,
    .windows => std.os.windows.HMODULE,
    
    else => @panic("Unsupported Platform")
},

binding: struct {
    Py_Initialize: *const @TypeOf(c.Py_Initialize),
    Py_InitializeFromConfig: *const @TypeOf(c.Py_InitializeFromConfig),
    Py_IncRef: *const @TypeOf(c.Py_IncRef),
    Py_DecRef: *const @TypeOf(c.Py_DecRef),
    Py_Finalize: *const @TypeOf(c.Py_Finalize),
    PyConfig_InitPythonConfig: *const @TypeOf(c.PyConfig_InitPythonConfig),
    PyConfig_InitIsolatedConfig: *const @TypeOf(c.PyConfig_InitIsolatedConfig),
    PyConfig_Clear: *const @TypeOf(c.PyConfig_Clear),
    PyConfig_SetBytesString: *const @TypeOf(c.PyConfig_SetBytesString),
    PyStatus_IsExit: *const @TypeOf(c.PyStatus_IsExit),
    PyStatus_IsError: *const @TypeOf(c.PyStatus_IsError),
    PyModule_GetDict: *const @TypeOf(c.PyModule_GetDict),
    PyDict_GetItemString: *const @TypeOf(c.PyDict_GetItemString),
    PyObject_CallObject: *const @TypeOf(c.PyObject_CallObject),
    PyLong_FromLong: *const @TypeOf(c.PyLong_FromLong),
    PyLong_AsLong: *const @TypeOf(c.PyLong_AsLong),
    PyFloat_FromDouble: *const @TypeOf(c.PyFloat_FromDouble),
    PyFloat_AsDouble: *const @TypeOf(c.PyFloat_AsDouble),
    PyUnicode_FromString: *const @TypeOf(c.PyUnicode_FromString),
    PyUnicode_AsUTF8AndSize: *const @TypeOf(c.PyUnicode_AsUTF8AndSize),
    PyTuple_New: *const @TypeOf(c.PyTuple_New),
    PyTuple_Size: *const @TypeOf(c.PyTuple_Size),
    PyTuple_GetItem: *const @TypeOf(c.PyTuple_GetItem),
    PyTuple_SetItem: *const @TypeOf(c.PyTuple_SetItem),
    PyErr_Clear: *const @TypeOf(c.PyErr_Clear),
    PyErr_Occurred: *const @TypeOf(c.PyErr_Occurred),
    PyRun_SimpleString: *const @TypeOf(c.PyRun_SimpleString),
    PyRun_SimpleFile: *const @TypeOf(c.PyRun_SimpleFile),
    PyImport_ImportModule: *const @TypeOf(c.PyImport_ImportModule),
    PyImport_AddModuleRef: *const @TypeOf(c.PyImport_AddModuleRef)
},

// A config.
pub const Config = struct {
    python: *Python,
    internal: *c.PyConfig,

    // Initialize a Python config.
    pub fn initPython(python: *Python) !Config {
        const internal = utilities.setReturn(c.struct_PyConfig, try python.allocator.create(c.struct_PyConfig), .{});

        c.PyConfig_InitPythonConfig(internal);

        return .{
            .python = python,
            .internal = internal
        };
    }

    // Initialize an isolated config.
    pub fn initIsolated(python: *Python) !Config {
        const internal = utilities.setReturn(c.struct_PyConfig, try python.allocator.create(c.struct_PyConfig), .{});

        c.PyConfig_InitIsolatedConfig(internal);

        return .{
            .python = python,
            .internal = internal
        };
    }

    // Deinitialize the config.
    pub fn deinit(self: Config) void {
        c.PyConfig_Clear(self.internal);
        self.python.allocator.destroy(self.internal);
    }

    // Set a string field.
    pub fn setString(self: Config, field: *[*c]c.wchar_t, string: []const u8) !void {
        const string_buffer = try self.python.allocator.dupeZ(u8, string);
        defer self.python.allocator.free(string_buffer);

        _ = c.PyConfig_SetBytesString(self.internal, field, string_buffer);
    }
};

// A status.
pub const Status = struct {
    python: *Python,
    internal: c.PyStatus,

    // Check if the status is the the result an exit.
    pub fn isExit(self: Status) bool {
        return c.PyStatus_IsExit(self.internal) == 1;
    }

    // Check if the status is the the result an error.
    pub fn isError(self: Status) bool {
        return c.PyStatus_IsError(self.internal) == 1;
    }
};

// An object.
pub const Object = struct {
    python: *Python,
    internal: *c.PyObject,

    // Initialize an object.
    pub fn init(python: *Python, internal: *c.PyObject) Object {
        return .{
            .python = python,
            .internal = internal
        };
    }

    // Initialize a long object.
    pub fn initLong(python: *Python, value: isize) !Object {
        if (c.PyLong_FromLong(@intCast(value))) |object| {
            return Object.init(python, object);
        }

        return error.LongInitializeFailed;
    }

    // Initialize a float object.
    pub fn initFloat(python: *Python, value: f32) !Object {
        if (c.PyFloat_FromDouble(@floatCast(value))) |object| {
            return Object.init(python, object);
        }

        return error.FloatInitializeFailed;
    }

    // Initialize an Unicode object.
    pub fn initUnicode(python: *Python, string: []const u8) !Object {
        const string_buffer = try python.allocator.dupeZ(u8, string);
        defer python.allocator.free(string_buffer);

        if (c.PyUnicode_FromString(string_buffer)) |object| {
            return Object.init(python, object);
        }

        return error.UnicodeInitializeFailed;
    }

    // Initialize a tuple.
    pub fn initTuple(python: *Python, length: usize) !Object {
        if (c.PyTuple_New(@intCast(length))) |object| {
            return Object.init(python, object);
        }

        return error.TupleInitializeFailed;
    }

    // Increase the reference count.
    pub fn increaseReference(self: Object) void {
        c.Py_IncRef(self.internal);
    }

    // Decrease the reference count.
    pub fn decreaseReference(self: Object) void {
        c.Py_DecRef(self.internal); 
    }

    // Read the object as an integer.
    pub fn asLong(self: Object) !isize {
        c.PyErr_Clear();

        const value = c.PyLong_AsLong(self.internal);

        if (value == -1 and c.PyErr_Occurred() != null) {
            return error.ReadLongFailed;
        }

        return @intCast(value);
    }

    // Read the object as a float.
    pub fn asFloat(self: Object) !f32 {
        c.PyErr_Clear();

        const value = c.PyFloat_AsDouble(self.internal);

        if (value == -1 and c.PyErr_Occurred() != null) {
            return error.ReadFloatFailed;
        }

        return @floatCast(value);
    }

    // Read the object as a string.
    pub fn asString(self: Object) ![]const u8 {
        var size: c.Py_ssize_t = undefined;
        var buffer = c.PyUnicode_AsUTF8AndSize(self.internal, &size);

        if (buffer == null) {
            return error.ReadStringFailed;
        }

        return buffer[0..size];
    }

    // Get the dictionary of the module.
    pub fn getModuleDictionary(self: Object) !Object {
        if (c.PyModule_GetDict(self.internal)) |object| {
            return Object.init(self.python, object);
        }

        return error.GetModuleDictionaryFailed;
    }

    // Get an item in the dictionary.
    pub fn getDictionaryItem(self: Object, name: []const u8) !Object {
        const name_buffer = try utilities.toNullTerminated(u8, 64, name);

        if (c.PyDict_GetItemString(self.internal, &name_buffer)) |object| {
            return Object.init(self.python, object);
        }

        return error.GetDictionaryitemFailed;
    }

    // Get the length of the tuple.
    pub fn getTupleLength(self: Object) usize {
        const result = c.PyTuple_Size(self.internal);

        if (result == -1) {
            return error.GetLengthFailed;
        }

        return @intCast(result);
    }

    // Get an item in the tuple.
    pub fn getTupleItem(self: Object, index: usize) !Object {
        if (c.PyTuple_GetItem(self.internal, @intCast(index))) |object| {
            return Object.init(self.python, object);
        }

        return error.OutOfBounds;
    }

    // Set an item in the tuple.
    pub fn setTupleItem(self: Object, index: usize, object: Object) !void {
        if (c.PyTuple_SetItem(self.internal, @intCast(index), object.internal) == -1) {
            return error.OutOfBounds;
        }
    }

    // Call the object.
    pub fn callObject(self: Object, arguments: ?Object) !Object {
        if (c.PyObject_CallObject(self.internal, if (arguments) |object| object.internal else null)) |object| {
            return Object.init(self.python, object);
        }

        return error.ObjectCallFailed;
    }
};

// Load a dynamic Python library.
pub fn load(_: []const u8, allocator: std.mem.Allocator) !Python {
    switch (builtin.os.tag) {
        .linux, .macos => {
            return .{
                .allocator = allocator,
                .handle = undefined,

                .binding = undefined
            };
        },

        .windows => {
            return .{
                .allocator = allocator,
                .handle = undefined,

                .binding = undefined
            };
        },

        else => @panic("Unsupported Platform")
    }
}

// Unload the dynamic Python library.
pub fn unload(_: *Python) void {
    std.debug.print("Python Unload\n", .{});
}

// Initialize the Python interpreter.
pub fn init(self: *Python) !void {
    const status = Status{
        .python = self,
        .internal = c.Py_Initialize()
    };

    if (status.isError()) {
        return error.InitializationFailed;
    }
}

// Initialize the Python interpreter from a config.
pub fn initFromConfig(self: *Python, config: Config) !void {
    const status = Status{
        .python = self,
        .internal = c.Py_InitializeFromConfig(config.internal)
    };

    if (status.isError()) {
        return error.InitializationFailed;
    }
}

// Deinitialize the Python interpreter.
pub fn deinit(_: *Python) void {
    std.debug.print("Python Deinitialize\n", .{});

    c.Py_Finalize();
}

// Run a string.
pub fn runString(self: *Python, string: []const u8) !void {
    const string_buffer = try self.allocator.dupeZ(u8, string);
    defer self.allocator.free(string_buffer);

    if (c.PyRun_SimpleString(string_buffer) == -1) {
        return error.RunFailed;
    }
}

// Run a file.
pub fn runFile(self: *Python, file: std.fs.File, filename: []const u8) !void {
    switch (builtin.os.tag) {
        .linux, .macos => {
            const handle = c.fdopen(file.handle, "r") orelse return error.FailedToOpenFile;

            _ = self.binding.PyRun_SimpleFile(handle, &try utilities.toNullTerminated(u8, 64, filename));
        },

        .windows => {
            const handle = c._open_osfhandle(@intCast(@intFromPtr(file.handle)), 0x0000);

            if (handle == -1) {
                return error.OpenFailed;
            }

            _ = self.binding.PyRun_SimpleFile(handle, &try utilities.toNullTerminated(u8, 64, filename));
        },

        else => @panic("Unsupported Platform")
    }
}

// Import a module.
pub fn importModule(self: *Python, name: []const u8) !Object {
    const name_buffer = try utilities.toNullTerminated(u8, 64, name);

    if (c.PyImport_ImportModule(&name_buffer)) |object| {
        return Object.init(self, object);
    }

    return error.ModuleNotFound;
}
