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

        python.binding.PyConfig_InitPythonConfig(internal);

        return .{
            .python = python,
            .allocator = python.allocator,
            .internal = internal
        };
    }

    // Initialize an isolated config.
    pub fn initIsolated(python: *Python) !Config {
        const internal = utilities.setReturn(c.struct_PyConfig, try python.allocator.create(c.struct_PyConfig), .{});

        python.binding.PyConfig_InitIsolatedConfig(internal);

        return .{
            .python = python,
            .internal = internal
        };
    }

    // Deinitialize the config.
    pub fn deinit(self: Config) void {
        self.python.binding.PyConfig_Clear(self.internal);
        self.python.allocator.destroy(self.internal);
    }

    // Set a string field.
    pub fn setString(self: Config, field: *[*c]c.wchar_t, string: []const u8) !void {
        const string_buffer = try self.python.allocator.dupeZ(u8, string);
        defer self.python.allocator.free(string_buffer);

        _ = self.python.binding.PyConfig_SetBytesString(self.internal, field, string_buffer);
    }
};

// A status.
pub const Status = struct {
    python: *Python,
    internal: c.PyStatus,

    // Check if the status is the the result an exit.
    pub fn isExit(self: Status) bool {
        return self.python.binding.PyStatus_IsExit(self.internal) == 1;
    }

    // Check if the status is the the result an error.
    pub fn isError(self: Status) bool {
        return self.python.binding.PyStatus_IsError(self.internal) == 1;
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
        if (python.binding.PyLong_FromLong(@intCast(value))) |object| {
            return Object.init(python, object);
        }

        return error.LongInitializeFailed;
    }

    // Initialize a float object.
    pub fn initFloat(python: *Python, value: f32) !Object {
        if (python.binding.PyFloat_FromDouble(@floatCast(value))) |object| {
            return Object.init(python, object);
        }

        return error.FloatInitializeFailed;
    }

    // Initialize an Unicode object.
    pub fn initUnicode(python: *Python, string: []const u8) !Object {
        const string_buffer = try python.allocator.dupeZ(u8, string);
        defer python.allocator.free(string_buffer);

        if (python.binding.PyUnicode_FromString(string_buffer)) |object| {
            return Object.init(python, object);
        }

        return error.UnicodeInitializeFailed;
    }

    // Initialize a tuple.
    pub fn initTuple(python: *Python, length: usize) !Object {
        if (python.binding.PyTuple_New(@intCast(length))) |object| {
            return Object.init(python, object);
        }

        return error.TupleInitializeFailed;
    }

    // Increase the reference count.
    pub fn increaseReference(self: Object) void {
        self.python.binding.Py_IncRef(self.internal);
    }

    // Decrease the reference count.
    pub fn decreaseReference(self: Object) void {
        self.python.binding.Py_DecRef(self.internal);
    }

    // Read the object as an integer.
    pub fn asLong(self: Object) !isize {
        self.python.binding.PyErr_Clear();

        const value = self.python.binding.PyLong_AsLong(self.internal);

        if (value == -1 and self.python.binding.PyErr_Occurred() != null) {
            return error.ReadLongFailed;
        }

        return @intCast(value);
    }

    // Read the object as a float.
    pub fn asFloat(self: Object) !f32 {
        self.python.binding.PyErr_Clear();

        const value = self.python.binding.PyFloat_AsDouble(self.internal);

        if (value == -1 and self.python.binding.PyErr_Occurred() != null) {
            return error.ReadFloatFailed;
        }

        return @floatCast(value);
    }

    // Read the object as a string.
    pub fn asString(self: Object) ![]const u8 {
        var size: c.Py_ssize_t = undefined;
        var buffer = self.python.binding.PyUnicode_AsUTF8AndSize(self.internal, &size);

        if (buffer == null) {
            return error.ReadStringFailed;
        }

        return buffer[0..size];
    }

    // Get the dictionary of the module.
    pub fn getModuleDictionary(self: Object) !Object {
        if (self.python.binding.PyModule_GetDict(self.internal)) |object| {
            return Object.init(self.python, object);
        }

        return error.GetModuleDictionaryFailed;
    }

    // Get an item in the dictionary.
    pub fn getDictionaryItem(self: Object, name: []const u8) !Object {
        const name_buffer = try utilities.toNullTerminated(u8, 64, name);

        if (self.python.binding.PyDict_GetItemString(self.internal, &name_buffer)) |object| {
            return Object.init(self.python, object);
        }

        return error.GetDictionaryitemFailed;
    }

    // Get the length of the tuple.
    pub fn getTupleLength(self: Object) usize {
        const result = self.python.binding.PyTuple_Size(self.internal);

        if (result == -1) {
            return error.GetLengthFailed;
        }

        return @intCast(result);
    }

    // Get an item in the tuple.
    pub fn getTupleItem(self: Object, index: usize) !Object {
        if (self.python.binding.PyTuple_GetItem(self.internal, @intCast(index))) |object| {
            return Object.init(self.python, object);
        }

        return error.OutOfBounds;
    }

    // Set an item in the tuple.
    pub fn setTupleItem(self: Object, index: usize, object: Object) !void {
        if (self.python.binding.PyTuple_SetItem(self.internal, @intCast(index), object.internal) == -1) {
            return error.OutOfBounds;
        }
    }

    // Call the object.
    pub fn callObject(self: Object, arguments: ?Object) !Object {
        if (self.python.binding.PyObject_CallObject(self.internal, if (arguments) |object| object.internal else null)) |object| {
            return Object.init(self.python, object);
        }

        return error.ObjectCallFailed;
    }
};

// Load a dynamic Python library.
pub fn load(path: []const u8, allocator: std.mem.Allocator) !Python {
    switch (builtin.os.tag) {
        .linux, .macos => {
            const handle = std.c.dlopen(&try std.posix.toPosixPath(path), .{ .LAZY = true, .GLOBAL = true }) orelse return error.FileNotFound;
            errdefer _ = std.c.dlclose(handle);

            return .{
                .allocator = allocator,
                .handle = handle,

                .binding = .{
                    .Py_Initialize = @ptrCast(std.c.dlsym(handle, "Py_Initialize") orelse return error.SymbolNotFound),
                    .Py_InitializeFromConfig = @ptrCast(std.c.dlsym(handle, "Py_InitializeFromConfig") orelse return error.SymbolNotFound),
                    .Py_IncRef = @ptrCast(std.c.dlsym(handle, "Py_IncRef") orelse return error.SymbolNotFound),
                    .Py_DecRef = @ptrCast(std.c.dlsym(handle, "Py_DecRef") orelse return error.SymbolNotFound),
                    .Py_Finalize = @ptrCast(std.c.dlsym(handle, "Py_Finalize") orelse return error.SymbolNotFound),
                    .PyConfig_InitPythonConfig = @ptrCast(std.c.dlsym(handle, "PyConfig_InitPythonConfig") orelse return error.SymbolNotFound),
                    .PyConfig_InitIsolatedConfig = @ptrCast(std.c.dlsym(handle, "PyConfig_InitIsolatedConfig") orelse return error.SymbolNotFound),
                    .PyConfig_Clear = @ptrCast(std.c.dlsym(handle, "PyConfig_Clear") orelse return error.SymbolNotFound),
                    .PyConfig_SetBytesString = @ptrCast(std.c.dlsym(handle, "PyConfig_SetBytesString") orelse return error.SymbolNotFound),
                    .PyStatus_IsExit = @ptrCast(std.c.dlsym(handle, "PyStatus_IsExit") orelse return error.SymbolNotFound),
                    .PyStatus_IsError = @ptrCast(std.c.dlsym(handle, "PyStatus_IsError") orelse return error.SymbolNotFound),
                    .PyModule_GetDict = @ptrCast(std.c.dlsym(handle, "PyModule_GetDict") orelse return error.SymbolNotFound),
                    .PyDict_GetItemString = @ptrCast(std.c.dlsym(handle, "PyDict_GetItemString") orelse return error.SymbolNotFound),
                    .PyObject_CallObject = @ptrCast(std.c.dlsym(handle, "PyObject_CallObject") orelse return error.SymbolNotFound),
                    .PyLong_FromLong = @ptrCast(std.c.dlsym(handle, "PyLong_FromLong") orelse return error.SymbolNotFound),
                    .PyLong_AsLong = @ptrCast(std.c.dlsym(handle, "PyLong_AsLong") orelse return error.SymbolNotFound),
                    .PyFloat_FromDouble = @ptrCast(std.c.dlsym(handle, "PyFloat_FromDouble") orelse return error.SymbolNotFound),
                    .PyFloat_AsDouble = @ptrCast(std.c.dlsym(handle, "PyFloat_AsDouble") orelse return error.SymbolNotFound),
                    .PyUnicode_FromString = @ptrCast(std.c.dlsym(handle, "PyUnicode_FromString") orelse return error.SymbolNotFound),
                    .PyUnicode_AsUTF8AndSize = @ptrCast(std.c.dlsym(handle, "PyUnicode_AsUTF8AndSize") orelse return error.SymbolNotFound),
                    .PyTuple_New = @ptrCast(std.c.dlsym(handle, "PyTuple_New") orelse return error.SymbolNotFound),
                    .PyTuple_Size = @ptrCast(std.c.dlsym(handle, "PyTuple_Size") orelse return error.SymbolNotFound),
                    .PyTuple_GetItem = @ptrCast(std.c.dlsym(handle, "PyTuple_GetItem") orelse return error.SymbolNotFound),
                    .PyTuple_SetItem = @ptrCast(std.c.dlsym(handle, "PyTuple_SetItem") orelse return error.SymbolNotFound),
                    .PyErr_Clear = @ptrCast(std.c.dlsym(handle, "PyErr_Clear") orelse return error.SymbolNotFound),
                    .PyErr_Occurred = @ptrCast(std.c.dlsym(handle, "PyErr_Occurred") orelse return error.SymbolNotFound),
                    .PyRun_SimpleString = @ptrCast(std.c.dlsym(handle, "PyRun_SimpleString") orelse return error.SymbolNotFound),
                    .PyRun_SimpleFile = @ptrCast(std.c.dlsym(handle, "PyRun_SimpleFile") orelse return error.SymbolNotFound),
                    .PyImport_ImportModule = @ptrCast(std.c.dlsym(handle, "PyImport_ImportModule") orelse return error.SymbolNotFound),
                    .PyImport_AddModuleRef = @ptrCast(std.c.dlsym(handle, "PyImport_AddModuleRef") orelse return error.SymbolNotFound)
                }
            };
        },

        .windows => {
            const wide_path = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
            defer allocator.free(wide_path);

            const handle = try std.os.windows.LoadLibraryW(wide_path);
            errdefer std.os.windows.FreeLibrary(handle);
            
            return .{
                .allocator = allocator,
                .handle = handle,

                .binding = .{
                    .Py_Initialize = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "Py_Initialize") orelse return error.SymbolNotFound),
                    .Py_InitializeFromConfig = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "Py_InitializeFromConfig") orelse return error.SymbolNotFound),
                    .Py_IncRef = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "Py_IncRef") orelse return error.SymbolNotFound),
                    .Py_DecRef = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "Py_DecRef") orelse return error.SymbolNotFound),
                    .Py_Finalize = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "Py_Finalize") orelse return error.SymbolNotFound),
                    .PyConfig_InitPythonConfig = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyConfig_InitPythonConfig") orelse return error.SymbolNotFound),
                    .PyConfig_InitIsolatedConfig = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyConfig_InitIsolatedConfig") orelse return error.SymbolNotFound),
                    .PyConfig_Clear = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyConfig_Clear") orelse return error.SymbolNotFound),
                    .PyConfig_SetBytesString = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyConfig_SetBytesString") orelse return error.SymbolNotFound),
                    .PyStatus_IsExit = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyStatus_IsExit") orelse return error.SymbolNotFound),
                    .PyStatus_IsError = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyStatus_IsError") orelse return error.SymbolNotFound),
                    .PyModule_GetDict = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyModule_GetDict") orelse return error.SymbolNotFound),
                    .PyDict_GetItemString = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyDict_GetItemString") orelse return error.SymbolNotFound),
                    .PyObject_CallObject = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyObject_CallObject") orelse return error.SymbolNotFound),
                    .PyLong_FromLong = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyLong_FromLong") orelse return error.SymbolNotFound),
                    .PyLong_AsLong = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyLong_AsLong") orelse return error.SymbolNotFound),
                    .PyFloat_FromDouble = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyFloat_FromDouble") orelse return error.SymbolNotFound),
                    .PyFloat_AsDouble = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyFloat_AsDouble") orelse return error.SymbolNotFound),
                    .PyUnicode_FromString = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyUnicode_FromString") orelse return error.SymbolNotFound),
                    .PyUnicode_AsUTF8AndSize = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyUnicode_AsUTF8AndSize") orelse return error.SymbolNotFound),
                    .PyTuple_New = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyTuple_New") orelse return error.SymbolNotFound),
                    .PyTuple_Size = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyTuple_Size") orelse return error.SymbolNotFound),
                    .PyTuple_GetItem = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyTuple_GetItem") orelse return error.SymbolNotFound),
                    .PyTuple_SetItem = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyTuple_SetItem") orelse return error.SymbolNotFound),
                    .PyErr_Clear = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyErr_Clear") orelse return error.SymbolNotFound),
                    .PyErr_Occurred = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyErr_Occurred") orelse return error.SymbolNotFound),
                    .PyRun_SimpleString = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyRun_SimpleString") orelse return error.SymbolNotFound),
                    .PyRun_SimpleFile = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyRun_SimpleFile") orelse return error.SymbolNotFound),
                    .PyImport_ImportModule = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyImport_ImportModule") orelse return error.SymbolNotFound),
                    .PyImport_AddModuleRef = @ptrCast(std.os.windows.kernel32.GetProcAddress(handle, "PyImport_AddModuleRef") orelse return error.SymbolNotFound)
                }
            };
        },

        else => @panic("Unsupported Platform")
    }
}

// Unload the dynamic Python library.
pub fn unload(self: *Python) void {
    std.debug.print("Python Unload\n", .{});

    switch (builtin.os.tag) {
        .linux, .macos => {
            _ = std.c.dlclose(self.handle);
        },

        .windows => {
            std.os.windows.FreeLibrary(self.handle);
        },

        else => @panic("Unsupported Platform")
    }
}

// Initialize the Python interpreter.
pub fn init(self: *Python) !void {
    const status = Status{
        .python = self,
        .internal = self.binding.Py_Initialize()
    };

    if (status.isError()) {
        return error.InitializationFailed;
    }
}

// Initialize the Python interpreter from a config.
pub fn initFromConfig(self: *Python, config: Config) !void {
    const status = Status{
        .python = self,
        .internal = self.binding.Py_InitializeFromConfig(config.internal)
    };

    if (status.isError()) {
        return error.InitializationFailed;
    }
}

// Deinitialize the Python interpreter.
pub fn deinit(self: *Python) void {
    std.debug.print("Python Deinitialize\n", .{});

    self.binding.Py_Finalize();
}

// Run a string.
pub fn runString(self: *Python, string: []const u8) !void {
    const string_buffer = try self.allocator.dupeZ(u8, string);
    defer self.allocator.free(string_buffer);

    if (self.binding.PyRun_SimpleString(string_buffer) == -1) {
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

    if (self.binding.PyImport_ImportModule(&name_buffer)) |object| {
        return Object.init(self, object);
    }

    return error.ModuleNotFound;
}
