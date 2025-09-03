const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Arity = @import("arity.zig").Arity;
const ExitCode = @import("exit_code.zig").ExitCode;
const exit = @import("exit_code.zig").exit;

/// Generic Argument constructor function
pub fn Argument(comptime T: type) type {
    return struct {
        const Self = @This();

        name: []const u8,
        description: []const u8,
        required: bool = false,
        default_value: ?ArrayList(T) = null,
        value: ?ArrayList(T) = null,
        allocator: Allocator,
        arity: Arity = Arity.zero_or_one,

        /// Initialize an argument with a name, description, required flag, and allocator
        pub fn init(name: []const u8, description: []const u8, required: bool, allocator: Allocator) !*Self {
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
            if (self.default_value != null) {
                self.default_value.?.deinit(self.allocator);
            }
            if (self.value != null) {
                self.value.?.deinit(self.allocator);
            }
            self.allocator.destroy(self);
        }

        /// Set the default values for the argument (only valid for optional arguments)
        pub fn withDefaultValues(self: *Self, default_values: []const T) *Self {
            if (self.default_value != null) {
                @panic("Default value already set");
            }
            if (!self.required) {
                if (default_values.len < self.arity.min or default_values.len > self.arity.max) {
                    @panic("Value length does not meet argument arity requirements");
                }
                self.default_value = ArrayList(T).empty;
                self.default_value.?.appendSlice(self.allocator, default_values) catch {
                    std.log.err("OutOfMemory when setting default value to {s}\n", .{self.name});
                    exit(ExitCode.OutOfMemory);
                };
            } else {
                @panic("Cannot set default value for required argument");
            }

            return self;
        }

        /// Convenience: set a single default value (arity max must be <= 1)
        pub fn withDefaultValue(self: *Self, value: T) *Self {
            if (self.arity.max > 1) @panic("withDefaultValue only valid when arity max <= 1");
            var buf: [1]T = undefined;
            buf[0] = value;
            return self.withDefaultValues(buf[0..1]);
        }

        /// Set the current values for the argument
        pub fn withValues(self: *Self, values: []const T) *Self {
            if (self.value != null) {
                @panic("Value already set");
            }
            if (values.len < self.arity.min or values.len > self.arity.max) {
                @panic("Value length does not meet argument arity requirements");
            }
            self.value = ArrayList(T).empty;
            self.value.?.appendSlice(self.allocator, values) catch {
                std.log.err("OutOfMemory when setting value to {s}\n", .{self.name});
                exit(ExitCode.OutOfMemory);
            };

            return self;
        }

        /// Convenience: set a single value (arity max must be <= 1)
        pub fn withValue(self: *Self, value: T) *Self {
            if (self.arity.max > 1) @panic("withValue (singular) only valid when arity max <= 1");
            var buf: [1]T = undefined;
            buf[0] = value;
            return self.withValues(buf[0..1]);
        }

        /// Set the arity for the argument
        pub fn withArity(self: *Self, arity: Arity) *Self {
            self.arity = arity;
            return self;
        }

        /// Get the value of the argument, returns default if not set, error if neither is available
        pub fn getValue(self: *Self) ![]T {
            if (self.value) |v| {
                return v.items;
            }
            if (self.default_value) |d| {
                return d.items;
            }
            if (self.required) {
                return error.RequiredArgumentMissing;
            }
            return error.NoValueSet;
        }

        /// Get the default value of the argument as a string, returns null if no value is set
        /// Caller owns the returned memory and must free both the individual strings and the array
        pub fn getDefaultValueAsString(self: *Self) !?[][]u8 {
            if (self.default_value) |default| {
                var result = std.ArrayList([]u8).empty;
                errdefer {
                    for (result.items) |str| {
                        self.allocator.free(str);
                    }
                    result.deinit(self.allocator);
                }

                for (default.items) |item| {
                    const item_str = try valueToString(T, item, self.allocator);
                    try result.append(self.allocator, item_str);
                }

                return try result.toOwnedSlice(self.allocator);
            }
            return null;
        }

        /// Get the name of the argument
        pub fn getName(self: *Self) []const u8 {
            return self.name;
        }

        /// Get the description of the argument
        pub fn getDescription(self: *Self) []const u8 {
            return self.description;
        }

        /// Get the arity of the argument
        pub fn getArity(self: *Self) Arity {
            return self.arity;
        }

        /// Check if the argument is required
        pub fn isRequired(self: *Self) bool {
            return self.required;
        }

        /// Check if the argument has a value set
        pub fn hasValue(self: *Self) bool {
            return self.value != null;
        }

        /// Check if the argument has a default value
        pub fn hasDefault(self: *Self) bool {
            return self.default_value != null;
        }

        /// Set the value of the argument
        pub fn setValue(self: *Self, value: T) void {
            if (self.value == null) {
                self.value = ArrayList(T).empty;
            }

            self.value.?.append(self.allocator, value) catch {
                std.log.err("OutOfMemory when setting value to {s}\n", .{self.name});
                exit(ExitCode.OutOfMemory);
            };
        }

        /// Validate that the argument meets its requirements
        pub fn validate(self: *Self) !void {
            if (self.required and self.value == null and self.default_value == null) {
                return error.RequiredArgumentMissing;
            }
        }
    };
}

/// Convert any typed value to its string representation
fn valueToString(comptime T: type, value: T, allocator: Allocator) ![]u8 {
    const type_info = @typeInfo(T);
    return switch (type_info) {
        .bool => try allocator.dupe(u8, if (value) "true" else "false"),
        .int => try std.fmt.allocPrint(allocator, "{d}", .{value}),
        .float => try std.fmt.allocPrint(allocator, "{d}", .{value}),
        .pointer => |ptr_info| switch (ptr_info.size) {
            .slice => if (ptr_info.child == u8)
                try allocator.dupe(u8, value)
            else blk: {
                // Handle dynamic slices
                var result = std.ArrayList(u8).empty;
                defer result.deinit(allocator);

                for (value, 0..) |item, i| {
                    if (i > 0) try result.append(',');
                    const item_str = try valueToString(@TypeOf(item), item, allocator);
                    defer allocator.free(item_str);
                    try result.appendSlice(allocator, item_str);
                }
                break :blk try result.toOwnedSlice();
            },
            else => try allocator.dupe(u8, "?"),
        },
        .@"enum" => blk: {
            // Convert enum to its field name
            const enum_info = type_info.@"enum";
            const int_value = @intFromEnum(value);

            inline for (enum_info.fields) |field| {
                if (field.value == int_value) {
                    break :blk try allocator.dupe(u8, field.name);
                }
            }

            // Fallback to numeric representation if field not found
            break :blk try std.fmt.allocPrint(allocator, "{d}", .{int_value});
        },
        .@"struct" => blk: {
            const json = std.json.Stringify.valueAlloc(allocator, value, .{}) catch {
                break :blk try allocator.dupe(u8, "?");
            };
            break :blk json; // caller owns and must free
        },
        else => try allocator.dupe(u8, "?"),
    };
}

/// Parse an enum value from a string
fn parseEnum(comptime EnumType: type, str_value: []const u8) !EnumType {
    const type_info = @typeInfo(EnumType);
    if (type_info != .@"enum") {
        @compileError("parseEnum only works with enum types");
    }

    // Check each enum field name
    inline for (type_info.@"enum".fields) |field| {
        if (std.mem.eql(u8, str_value, field.name)) {
            return @enumFromInt(field.value);
        }
    }

    return error.InvalidEnumValue;
}

/// Parse a JSON string into the specified struct type
fn parseStruct(comptime StructType: type, str_value: []const u8, allocator: Allocator) !StructType {
    const type_info = @typeInfo(StructType);
    if (type_info != .@"struct") {
        @compileError("parseStruct only works with struct types");
    }

    // Parse JSON string into the struct
    const parsed = std.json.parseFromSlice(
        StructType,
        allocator,
        str_value,
        .{
            .ignore_unknown_fields = true,
        },
    ) catch |err| switch (err) {
        error.SyntaxError, error.UnexpectedToken, error.InvalidCharacter, error.UnexpectedEndOfInput => return error.InvalidJsonFormat,
        error.MissingField => return error.MissingRequiredField,
        error.UnknownField => return error.UnknownJsonField,
        else => return err,
    };
    defer parsed.deinit();

    return parsed.value;
}

/// Parse a string value into the specified type
pub fn parseValueFromString(comptime T: type, str_value: []const u8) !T {
    const type_info = @typeInfo(T);
    return switch (type_info) {
        .bool => std.mem.eql(u8, str_value, "true") or std.mem.eql(u8, str_value, "1"),
        .int => try std.fmt.parseInt(T, str_value, 10),
        .float => try std.fmt.parseFloat(T, str_value),
        .pointer => |ptr_info| switch (ptr_info.size) {
            .slice => if (ptr_info.child == u8)
                str_value
            else
                return error.UnsupportedSliceType, // Slices need allocator, use parseValueFromStringWithAllocator
            else => return error.UnsupportedPointerType,
        },
        .@"enum" => try parseEnum(T, str_value),
        .array => return error.UnsupportedArrayType, // Arrays need allocator, use parseValueFromStringWithAllocator
        else => return error.UnsupportedType,
    };
}

/// Parse a string value into the specified type with allocator support for dynamic types
pub fn parseValueFromStringWithAllocator(comptime T: type, str_value: []const u8, allocator: Allocator) !T {
    const type_info = @typeInfo(T);
    return switch (type_info) {
        .bool => std.mem.eql(u8, str_value, "true") or std.mem.eql(u8, str_value, "1"),
        .int => try std.fmt.parseInt(T, str_value, 10),
        .float => try std.fmt.parseFloat(T, str_value),
        .pointer => |ptr_info| switch (ptr_info.size) {
            .slice => str_value,
            else => return error.UnsupportedPointerType,
        },
        .@"enum" => try parseEnum(T, str_value),
        .@"struct" => try parseStruct(T, str_value, allocator),
        else => return error.UnsupportedType,
    };
}

/// ArgumentInterface provides a type-erased interface for working with arguments of different types
pub const ArgumentInterface = struct {
    const Self = @This();

    ptr: *anyopaque,
    vtable: *const ArgumentVTable,

    const ArgumentVTable = struct {
        getDescription: *const fn (ptr: *anyopaque) []const u8,
        getDefaultValueAsString: *const fn (ptr: *anyopaque, allocator: Allocator) anyerror!?[]u8,
        getValueAsString: *const fn (ptr: *anyopaque, allocator: Allocator) anyerror!?[][]u8,
        setValueFromString: *const fn (ptr: *anyopaque, value: []const u8) anyerror!void,
        getArity: *const fn (ptr: *anyopaque) Arity,
        hasValue: *const fn (ptr: *anyopaque) bool,
        getName: *const fn (ptr: *anyopaque) []const u8,
        isRequired: *const fn (ptr: *anyopaque) bool,
        hasDefault: *const fn (ptr: *anyopaque) bool,
        type_name: []const u8,
    };

    /// Create an ArgumentInterface from a typed argument
    pub fn init(comptime InnerType: type, arg_ptr: *Argument(InnerType)) Self {
        const T = @TypeOf(arg_ptr.*);

        const VTable = struct {
            const vtable = ArgumentVTable{
                .getDescription = struct {
                    fn getDescription(ptr: *anyopaque) []const u8 {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        return self.getDescription();
                    }
                }.getDescription,
                .getDefaultValueAsString = struct {
                    fn getDefaultValueAsString(ptr: *anyopaque, allocator: Allocator) anyerror!?[]u8 {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        const values = self.getDefaultValueAsString() catch return null;
                        if (values == null) return null;

                        // Convert array of strings to single comma-separated string
                        if (values.?.len == 0) return try allocator.dupe(u8, "");
                        if (values.?.len == 1) return try allocator.dupe(u8, values.?[0]);

                        var result = std.ArrayList(u8).empty;
                        defer result.deinit(self.allocator);

                        for (values.?, 0..) |value, i| {
                            if (i > 0) try result.appendSlice(allocator, ", ");
                            try result.appendSlice(allocator, value);
                        }

                        return try result.toOwnedSlice(allocator);
                    }
                }.getDefaultValueAsString,
                .getValueAsString = struct {
                    fn getValueAsString(ptr: *anyopaque, allocator: Allocator) anyerror!?[][]u8 {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        const values = self.getValue() catch return null;

                        // Convert array of values to array of strings
                        var result = std.ArrayList([]u8).empty;
                        errdefer {
                            for (result.items) |str| {
                                allocator.free(str);
                            }
                            result.deinit(self.allocator);
                        }

                        for (values) |value| {
                            const value_str = try valueToString(InnerType, value, allocator);
                            try result.append(allocator, value_str);
                        }

                        return try result.toOwnedSlice(allocator);
                    }
                }.getValueAsString,
                .setValueFromString = struct {
                    fn setValueFromString(ptr: *anyopaque, str_value: []const u8) anyerror!void {
                        const self: *T = @ptrCast(@alignCast(ptr));

                        const inner_type_info = @typeInfo(InnerType);
                        const needs_allocator = switch (inner_type_info) {
                            .array => true,
                            .pointer => |ptr_info| ptr_info.size == .slice and ptr_info.child != u8,
                            .@"struct" => true,
                            else => false,
                        };

                        const typed_value = if (needs_allocator)
                            try parseValueFromStringWithAllocator(InnerType, str_value, self.allocator)
                        else
                            try parseValueFromString(InnerType, str_value);

                        self.setValue(typed_value);
                    }
                }.setValueFromString,
                .getArity = struct {
                    fn getArity(ptr: *anyopaque) Arity {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        return self.getArity();
                    }
                }.getArity,
                .hasValue = struct {
                    fn hasValue(ptr: *anyopaque) bool {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        return self.value != null;
                    }
                }.hasValue,
                .getName = struct {
                    fn getName(ptr: *anyopaque) []const u8 {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        return self.getName();
                    }
                }.getName,
                .isRequired = struct {
                    fn isRequired(ptr: *anyopaque) bool {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        return self.isRequired();
                    }
                }.isRequired,
                .hasDefault = struct {
                    fn hasDefault(ptr: *anyopaque) bool {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        return self.hasDefault();
                    }
                }.hasDefault,
                .type_name = @typeName(InnerType),
            };
        };

        return Self{
            .ptr = arg_ptr,
            .vtable = &VTable.vtable,
        };
    }

    /// Get the description of the option
    pub fn getDescription(self: Self) []const u8 {
        return self.vtable.getDescription(self.ptr);
    }

    /// Get the default value as a string, returns null if no default is set
    pub fn getDefaultValueAsString(self: Self, allocator: Allocator) !?[]u8 {
        return self.vtable.getDefaultValueAsString(self.ptr, allocator);
    }

    /// Get the value of the option as an array of strings, returns null if no value is set
    /// Caller owns the returned memory and must free both the individual strings and the array
    pub fn getValueAsString(self: Self, allocator: Allocator) !?[][]u8 {
        return self.vtable.getValueAsString(self.ptr, allocator);
    }

    /// Set the value of the option from a string
    pub fn setValueFromString(self: Self, value: []const u8) !void {
        return self.vtable.setValueFromString(self.ptr, value);
    }

    /// Check if the option has a value set
    pub fn hasValue(self: Self) bool {
        return self.vtable.hasValue(self.ptr);
    }

    /// Get the long name of the option
    pub fn getName(self: Self) []const u8 {
        return self.vtable.getName(self.ptr);
    }

    /// Check if the argument is required
    pub fn isRequired(self: Self) bool {
        return self.vtable.isRequired(self.ptr);
    }

    /// Check if the argument has a default value
    pub fn hasDefault(self: Self) bool {
        return self.vtable.hasDefault(self.ptr);
    }

    /// Get the arity of the argument
    pub fn getArity(self: Self) Arity {
        return self.vtable.getArity(self.ptr);
    }

    /// Get the type name of the argument
    pub fn getTypeName(self: Self) []const u8 {
        return self.vtable.type_name;
    }
};
