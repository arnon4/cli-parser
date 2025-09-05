const std = @import("std");
const Allocator = std.mem.Allocator;
const ActionError = error{
    InvalidType,
    OptionNotFound,
    ArgumentNotFound,
    Overflow,
    InvalidCharacter,
    UnexpectedToken,
    InvalidNumber,
    InvalidEnumTag,
    DuplicateField,
    UnknownField,
    MissingField,
    LengthMismatch,
    OutOfMemory,
    SyntaxError,
    UnexpectedEndOfInput,
    BufferUnderrun,
    ValueTooLong,
};

/// Context containing parsed CLI values
pub const ActionContext = struct {
    const Self = @This();

    parent: ?*Self = null,
    child: ?*Self = null,
    options: std.StringHashMap(ParsedValue),
    flags: std.StringHashMap(bool),
    arguments: std.StringHashMap(ParsedValue),
    allocator: Allocator,

    pub const ParsedValue = struct {
        value: []const u8,

        pub const StructData = struct {
            ptr: *anyopaque,
            type_info: TypeInfo,
            deinit_fn: ?*const fn (ptr: *anyopaque, allocator: Allocator) void,
        };

        pub const TypeInfo = struct {
            name: []const u8,
            size: usize,
            alignment: u29,
        };

        pub fn asString(self: ParsedValue) []const u8 {
            return self.value;
        }

        pub fn asInt(self: ParsedValue, comptime T: type) ActionError!T {
            return try std.fmt.parseInt(T, self.value, 10);
        }

        pub fn asFloat(self: ParsedValue, comptime T: type) ActionError!T {
            return try std.fmt.parseFloat(T, self.value);
        }

        pub fn asBool(self: ParsedValue) bool {
            return std.mem.eql(u8, self.value, "true") or std.mem.eql(u8, self.value, "1");
        }

        pub fn asStruct(self: ParsedValue, comptime T: type, allocator: Allocator) ActionError!std.json.Parsed(T) {
            return try std.json.parseFromSlice(T, allocator, self.value, .{});
        }

        /// Create a ParsedValue from a struct
        pub fn fromStruct(comptime T: type, value: T, allocator: Allocator) ActionError!ParsedValue {
            const ptr = allocator.create(T) catch return ActionError.OutOfMemory;
            ptr.* = value;

            return ParsedValue{
                .struct_data = StructData{
                    .ptr = ptr,
                    .type_info = TypeInfo{
                        .name = @typeName(T),
                        .size = @sizeOf(T),
                        .alignment = @alignOf(T),
                    },
                    .deinit_fn = struct {
                        fn deinit(ptr_opaque: *anyopaque, alloc: Allocator) void {
                            const typed_ptr: *T = @ptrCast(@alignCast(ptr_opaque));
                            alloc.destroy(typed_ptr);
                        }
                    }.deinit,
                },
            };
        }
    };

    /// Initialize the action context
    pub fn init(allocator: Allocator, parent: ?*Self) !*Self {
        const self = try allocator.create(ActionContext);

        if (parent) |p| {
            self.parent = p;
            p.child = self;
        } else {
            self.parent = null;
        }

        self.child = null;

        self.options = std.StringHashMap(ParsedValue).init(allocator);
        self.flags = std.StringHashMap(bool).init(allocator);
        self.arguments = std.StringHashMap(ParsedValue).init(allocator);
        self.allocator = allocator;
        return self;
    }

    /// Deinitialize the context
    pub fn deinit(self: *Self) void {
        // Free all owned strings in options
        var option_iter = self.options.iterator();
        while (option_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*.value);
        }
        self.options.deinit();

        self.flags.deinit();

        // Free all owned strings in arguments
        var arg_iter = self.arguments.iterator();
        while (arg_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*.value);
        }
        self.arguments.deinit();

        // Free the allocated ActionContext itself
        self.allocator.destroy(self);
        if (self.parent) |p| {
            p.child = null;
            p.deinit();
        }
    }

    /// Set an option value
    pub fn setOption(self: *Self, name: []const u8, value: ParsedValue) !void {
        try self.options.put(name, value);
    }

    /// Set a flag value
    pub fn setFlag(self: *Self, name: []const u8, value: bool) !void {
        try self.flags.put(name, value);
    }

    /// Set an argument value
    pub fn setArgument(self: *Self, name: []const u8, value: ParsedValue) !void {
        try self.arguments.put(name, value);
    }

    /// Get an option value by name and type
    pub fn getOption(self: *const Self, comptime T: type, name: []const u8) !T {
        if (self.options.get(name)) |value| {
            const requested_type = @typeInfo(T);
            switch (requested_type) {
                .int => return value.asInt(T),
                .float => return value.asFloat(T),
                .bool => return value.asBool(),
                .pointer => |ptr_info| {
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        return value.asString();
                    } else {
                        return ActionError.InvalidType;
                    }
                },
                .array => return value.asString(),
                .@"struct" => {
                    const parsed = try value.asStruct(T, self.allocator);
                    defer parsed.deinit();
                    return parsed.value;
                },
                else => return ActionError.InvalidType,
            }
        } else if (self.parent) |parent| {
            return parent.getOption(T, name);
        }
        return ActionError.OptionNotFound;
    }

    /// Get a flag value by name
    pub fn getFlag(self: *const Self, name: []const u8) bool {
        if (self.flags.get(name)) |value| {
            return value;
        } else if (self.parent) |parent| {
            return parent.getFlag(name);
        }

        return false;
    }

    /// Get an argument value by name and type
    pub fn getArgument(self: *const Self, comptime T: type, name: []const u8) ActionError!T {
        if (self.arguments.get(name)) |value| {
            const requested_type = @typeInfo(T);
            switch (requested_type) {
                .int => return value.asInt(T),
                .float => return value.asFloat(T),
                .bool => return value.asBool(),
                .pointer => |ptr_info| {
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        return value.asString();
                    } else {
                        return ActionError.InvalidType;
                    }
                },
                .array => return value.asString(),
                .@"struct" => {
                    const parsed = try value.asStruct(T, self.allocator);
                    defer parsed.deinit();
                    return parsed.value;
                },
                else => return ActionError.InvalidType,
            }
        } else if (self.parent) |parent| {
            return parent.getArgument(T, name);
        }
        return ActionError.ArgumentNotFound;
    }
};
