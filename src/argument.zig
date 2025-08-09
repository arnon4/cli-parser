const std = @import("std");
const testing = std.testing;

/// Generic Argument constructor function
pub fn Argument(comptime T: type) type {
    return struct {
        const Self = @This();

        name: []const u8,
        description: []const u8,
        required: bool,
        default_value: ?T = null,
        value: ?T = null,
        allocator: std.mem.Allocator,

        /// Initialize an argument with a name, description, required flag, and allocator
        pub fn init(name: []const u8, description: []const u8, required: bool, allocator: std.mem.Allocator) !*Self {
            const argument = try allocator.create(Self);
            argument.* = Self{
                .name = name,
                .description = description,
                .required = required,
                .allocator = allocator,
            };
            return argument;
        }

        /// Deinitialize the argument
        pub fn deinit(self: *Self) void {
            self.allocator.destroy(self);
        }

        /// Set the default value for the argument (only valid for optional arguments)
        pub fn withDefault(self: *Self, default_value: T) *Self {
            if (!self.required) {
                self.default_value = default_value;
            }
            return self;
        }

        /// Set the current value for the argument
        pub fn withValue(self: *Self, value: T) *Self {
            self.value = value;
            return self;
        }

        /// Get the value of the argument, returns default if not set, error if neither is available
        pub fn getValue(self: *const Self) !T {
            if (self.value) |v| {
                return v;
            }
            if (self.default_value) |d| {
                return d;
            }
            if (self.required) {
                return error.RequiredArgumentMissing;
            }
            return error.NoValueSet;
        }

        /// Get the name of the argument
        pub fn getName(self: *const Self) []const u8 {
            return self.name;
        }

        /// Get the description of the argument
        pub fn getDescription(self: *const Self) []const u8 {
            return self.description;
        }

        /// Check if the argument is required
        pub fn isRequired(self: *const Self) bool {
            return self.required;
        }

        /// Check if the argument has a value set
        pub fn hasValue(self: *const Self) bool {
            return self.value != null;
        }

        /// Check if the argument has a default value
        pub fn hasDefault(self: *const Self) bool {
            return self.default_value != null;
        }

        /// Set the value of the argument
        pub fn setValue(self: *Self, value: T) void {
            self.value = value;
        }

        /// Reset the argument to its default state
        pub fn reset(self: *Self) void {
            self.value = null;
        }

        /// Validate that the argument meets its requirements
        pub fn validate(self: *const Self) !void {
            if (self.required and self.value == null and self.default_value == null) {
                return error.RequiredArgumentMissing;
            }
        }
    };
}

/// ArgumentInterface provides a type-erased interface for working with arguments of different types
pub const ArgumentInterface = struct {
    const Self = @This();

    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        getName: *const fn (ptr: *anyopaque) []const u8,
        getDescription: *const fn (ptr: *anyopaque) []const u8,
        isRequired: *const fn (ptr: *anyopaque) bool,
        hasValue: *const fn (ptr: *anyopaque) bool,
        hasDefault: *const fn (ptr: *anyopaque) bool,
        setValue: *const fn (ptr: *anyopaque, value: []const u8) anyerror!void,
        getValue: *const fn (ptr: *anyopaque) anyerror![]const u8,
        validate: *const fn (ptr: *anyopaque) anyerror!void,
        reset: *const fn (ptr: *anyopaque) void,
        deinit: *const fn (ptr: *anyopaque) void,
        getTypeInfo: *const fn () TypeInfo,
    };

    /// Type information for runtime type identification
    pub const TypeInfo = struct {
        name: []const u8,
        hash: u64,

        pub fn create(comptime T: type) TypeInfo {
            const type_name = @typeName(T);
            return TypeInfo{
                .name = type_name,
                .hash = comptime std.hash_map.hashString(type_name),
            };
        }
    };

    /// Create an ArgumentInterface from a concrete Argument(T)
    pub fn create(comptime T: type, argument: *Argument(T)) ArgumentInterface {
        const Impl = struct {
            const VTableImpl = VTable{
                .getName = getNameImpl,
                .getDescription = getDescriptionImpl,
                .isRequired = isRequiredImpl,
                .hasValue = hasValueImpl,
                .hasDefault = hasDefaultImpl,
                .setValue = setValueImpl,
                .getValue = getValueImpl,
                .validate = validateImpl,
                .reset = resetImpl,
                .deinit = deinitImpl,
                .getTypeInfo = getTypeInfoImpl,
            };

            fn getNameImpl(ptr: *anyopaque) []const u8 {
                const self: *Argument(T) = @ptrCast(@alignCast(ptr));
                return self.getName();
            }

            fn getDescriptionImpl(ptr: *anyopaque) []const u8 {
                const self: *Argument(T) = @ptrCast(@alignCast(ptr));
                return self.getDescription();
            }

            fn isRequiredImpl(ptr: *anyopaque) bool {
                const self: *Argument(T) = @ptrCast(@alignCast(ptr));
                return self.isRequired();
            }

            fn hasValueImpl(ptr: *anyopaque) bool {
                const self: *Argument(T) = @ptrCast(@alignCast(ptr));
                return self.hasValue();
            }

            fn hasDefaultImpl(ptr: *anyopaque) bool {
                const self: *Argument(T) = @ptrCast(@alignCast(ptr));
                return self.hasDefault();
            }

            fn setValueImpl(ptr: *anyopaque, value: []const u8) anyerror!void {
                const self: *Argument(T) = @ptrCast(@alignCast(ptr));
                const parsed_value = try parseValueFromString(T, value);
                self.setValue(parsed_value);
            }

            fn getValueImpl(ptr: *anyopaque) anyerror![]const u8 {
                const self: *Argument(T) = @ptrCast(@alignCast(ptr));
                const value = try self.getValue();
                return try valueToString(T, value, self.allocator);
            }

            fn validateImpl(ptr: *anyopaque) anyerror!void {
                const self: *Argument(T) = @ptrCast(@alignCast(ptr));
                try self.validate();
            }

            fn resetImpl(ptr: *anyopaque) void {
                const self: *Argument(T) = @ptrCast(@alignCast(ptr));
                self.reset();
            }

            fn deinitImpl(ptr: *anyopaque) void {
                const self: *Argument(T) = @ptrCast(@alignCast(ptr));
                self.deinit();
            }

            fn getTypeInfoImpl() TypeInfo {
                return TypeInfo.create(T);
            }
        };

        return ArgumentInterface{
            .ptr = argument,
            .vtable = &Impl.VTableImpl,
        };
    }

    /// Get the name of the argument
    pub fn getName(self: *const Self) []const u8 {
        return self.vtable.getName(self.ptr);
    }

    /// Get the description of the argument
    pub fn getDescription(self: *const Self) []const u8 {
        return self.vtable.getDescription(self.ptr);
    }

    /// Check if the argument is required
    pub fn isRequired(self: *const Self) bool {
        return self.vtable.isRequired(self.ptr);
    }

    /// Check if the argument has a value set
    pub fn hasValue(self: *const Self) bool {
        return self.vtable.hasValue(self.ptr);
    }

    /// Check if the argument has a default value
    pub fn hasDefault(self: *const Self) bool {
        return self.vtable.hasDefault(self.ptr);
    }

    /// Set the value of the argument from a string
    pub fn setValue(self: *const Self, value: []const u8) anyerror!void {
        try self.vtable.setValue(self.ptr, value);
    }

    /// Get the value of the argument as a string
    pub fn getValue(self: *const Self) anyerror![]const u8 {
        return try self.vtable.getValue(self.ptr);
    }

    /// Validate that the argument meets its requirements
    pub fn validate(self: *const Self) anyerror!void {
        try self.vtable.validate(self.ptr);
    }

    /// Reset the argument to its default state
    pub fn reset(self: *const Self) void {
        self.vtable.reset(self.ptr);
    }

    /// Deinitialize the argument and free its memory
    pub fn deinit(self: *const Self) void {
        self.vtable.deinit(self.ptr);
    }

    /// Get type information for the argument
    pub fn getTypeInfo(self: *const Self) TypeInfo {
        return self.vtable.getTypeInfo();
    }
};

/// Convert a value of any type to its string representation
fn valueToString(comptime T: type, value: T, allocator: std.mem.Allocator) ![]const u8 {
    switch (@typeInfo(T)) {
        .bool => return if (value) "true" else "false",
        .int, .float => {
            var buffer: [64]u8 = undefined;
            const str = try std.fmt.bufPrint(&buffer, "{}", .{value});
            return try allocator.dupe(u8, str);
        },
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                // String slice
                return try allocator.dupe(u8, value);
            }
        },
        .array => |array_info| {
            if (array_info.child == u8) {
                // String array
                return try allocator.dupe(u8, &value);
            }
        },
        .@"struct", .@"union", .@"enum" => {
            // Use JSON for complex types
            var string = std.ArrayList(u8).init(allocator);
            defer string.deinit();
            try std.json.stringify(value, .{}, string.writer());
            return try string.toOwnedSlice();
        },
        else => {},
    }

    // Fallback: convert to JSON
    var string = std.ArrayList(u8).init(allocator);
    defer string.deinit();
    try std.json.stringify(value, .{}, string.writer());
    return try string.toOwnedSlice();
}

/// Parse a value of any type from its string representation
fn parseValueFromString(comptime T: type, str: []const u8) !T {
    switch (@typeInfo(T)) {
        .bool => {
            if (std.mem.eql(u8, str, "true")) return true;
            if (std.mem.eql(u8, str, "false")) return false;
            return error.InvalidBoolValue;
        },
        .int => return try std.fmt.parseInt(T, str, 10),
        .float => return try std.fmt.parseFloat(T, str),
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                return str;
            }
        },
        .array => |array_info| {
            if (array_info.child == u8 and array_info.len == str.len) {
                var result: T = undefined;
                @memcpy(&result, str[0..array_info.len]);
                return result;
            }
        },
        .@"struct", .@"union", .@"enum" => {
            // Use JSON parsing for complex types
            const parsed = try std.json.parseFromSlice(T, std.heap.page_allocator, str, .{});
            return parsed.value;
        },
        else => {},
    }

    return error.UnsupportedType;
}
