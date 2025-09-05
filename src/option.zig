const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const ActionContext = @import("action_context.zig").ActionContext;
const Arity = @import("arity.zig").Arity;
const ExitCode = @import("exit_code.zig").ExitCode;
const exit = @import("exit_code.zig").exit;

/// Generic Option constructor function
pub fn Option(comptime T: type) type {
    return struct {
        const Self = @This();

        name: ?[]const u8 = null,
        short: ?u8 = null,
        description: []const u8,
        default_value: ?ArrayList(T) = null,
        value: ?ArrayList(T) = null,
        allocator: Allocator,
        arity: Arity = Arity.zero_or_one,

        /// Initialize an option
        pub fn init(description: []const u8, allocator: Allocator) !*Self {
            const option = try allocator.create(Self);
            option.* = Self{
                .description = description,
                .allocator = allocator,
            };
            return option;
        }

        /// Deinitialize the option and free its memory
        pub fn deinit(self: *Self) void {
            if (self.default_value != null) {
                self.default_value.?.deinit(self.allocator);
            }
            if (self.value != null) {
                self.value.?.deinit(self.allocator);
            }
            self.allocator.destroy(self);
        }

        /// Set the long name for the option (e.g., "verbose")
        pub fn withName(self: *Self, name: []const u8) *Self {
            self.name = name;
            return self;
        }

        /// Set the short name for the option (e.g., 'v')
        pub fn withShort(self: *Self, short: u8) *Self {
            self.short = short;
            return self;
        }

        /// Set the default values for the option
        pub fn withDefaultValues(self: *Self, default_values: []const T) *Self {
            if (self.default_value != null) {
                @panic("Default value already set");
            }
            if (default_values.len < self.arity.min or default_values.len > self.arity.max) {
                @panic("Value length does not meet option arity requirements");
            }
            self.default_value = ArrayList(T).empty;
            self.default_value.?.appendSlice(self.allocator, default_values) catch {
                std.log.err("OutOfMemory when setting default value for option\n", .{});
                exit(ExitCode.OutOfMemory);
            };
            return self;
        }

        /// Convenience: set a single default value (only if arity allows at most 1)
        pub fn withDefaultValue(self: *Self, value: T) *Self {
            if (self.arity.max > 1) @panic("withDefaultValue only valid when arity max <= 1");
            var buf: [1]T = undefined;
            buf[0] = value;
            return self.withDefaultValues(buf[0..1]);
        }

        /// Set the current values for the option
        pub fn withValues(self: *Self, values: []const T) *Self {
            if (self.value != null) {
                @panic("Value already set");
            }
            if (values.len < self.arity.min or values.len > self.arity.max) {
                @panic("Value length does not meet option arity requirements");
            }
            self.value = ArrayList(T).empty;
            self.value.?.appendSlice(self.allocator, values) catch {
                std.log.err("OutOfMemory when setting value for option\n", .{});
                exit(ExitCode.OutOfMemory);
            };
            return self;
        }

        /// Convenience: set a single value (only if arity allows at most 1)
        pub fn withValue(self: *Self, value: T) *Self {
            if (self.arity.max > 1) @panic("withValue (singular) only valid when arity max <= 1");
            var buf: [1]T = undefined;
            buf[0] = value;
            return self.withValues(buf[0..1]);
        }

        /// Set the arity for the option
        pub fn withArity(self: *Self, arity: Arity) *Self {
            self.arity = arity;
            return self;
        }

        /// Get the description of the option
        pub fn getDescription(self: *const Self) []const u8 {
            return self.description;
        }

        /// Get the default value as a string, returns `null` if no default is set.
        /// Caller owns the returned memory and must free both the individual strings and the array
        pub fn getDefaultValueAsString(self: *const Self) !?[][]u8 {
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

        /// Get the value of the option, returns default if not set, error if neither is available
        pub fn getValue(self: *const Self) ![]T {
            if (self.value) |v| {
                return v.items;
            }
            if (self.default_value) |d| {
                return d.items;
            }
            return error.NoValueSet;
        }

        /// Get the long name of the option
        pub fn getName(self: *const Self) ?[]const u8 {
            return self.name;
        }

        /// Get the short name of the option
        pub fn getShort(self: *const Self) ?u8 {
            return self.short;
        }

        /// Get the arity of the option
        pub fn getArity(self: *const Self) Arity {
            return self.arity;
        }

        /// Check if the option has a value set
        pub fn hasValue(self: *const Self) bool {
            return self.value != null;
        }

        /// Check if the option has a default value
        pub fn hasDefault(self: *const Self) bool {
            return self.default_value != null;
        }

        /// Set the value of the option
        pub fn setValue(self: *Self, value: T) void {
            if (self.value == null) {
                self.value = ArrayList(T).empty;
            }

            self.value.?.append(self.allocator, value) catch {
                std.log.err("OutOfMemory when setting value for option\n", .{});
                exit(ExitCode.OutOfMemory);
            };
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
        error.SyntaxError => return error.InvalidJsonFormat,
        error.UnexpectedToken => return error.InvalidJsonFormat,
        error.InvalidCharacter => return error.InvalidJsonFormat,
        error.UnexpectedEndOfInput => return error.InvalidJsonFormat,
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

/// Interface for type-erased option handling
pub const OptionInterface = struct {
    ptr: *anyopaque,
    vtable: *const OptionVTable,

    const Self = @This();

    const OptionVTable = struct {
        getDescription: *const fn (ptr: *anyopaque) []const u8,
        getDefaultValueAsString: *const fn (ptr: *anyopaque) anyerror!?[]u8,
        getValueAsString: *const fn (ptr: *anyopaque, allocator: Allocator) anyerror!?[][]u8,
        setValueFromString: *const fn (ptr: *anyopaque, value: []const u8) anyerror!void,
        hasValue: *const fn (ptr: *anyopaque) bool,
        getName: *const fn (ptr: *anyopaque) ?[]const u8,
        getShort: *const fn (ptr: *anyopaque) ?u8,
        getArity: *const fn (ptr: *anyopaque) Arity,
        hasDefault: *const fn (ptr: *anyopaque) bool,
        type_name: []const u8,
    };

    /// Create an OptionInterface from a typed option
    pub fn init(comptime InnerType: type, option_ptr: *Option(InnerType)) Self {
        const T = @TypeOf(option_ptr.*);

        const Vtable = struct {
            const vtable = OptionVTable{
                .getDescription = struct {
                    fn getDescription(ptr: *anyopaque) []const u8 {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        return self.getDescription();
                    }
                }.getDescription,
                .getDefaultValueAsString = struct {
                    fn getDefaultValueAsString(ptr: *anyopaque) anyerror!?[]u8 {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        const values = self.getDefaultValueAsString() catch return null;
                        if (values == null) return null; // nothing set

                        var ret_slice: ?[]u8 = null;
                        defer {
                            // Free original per-item allocations and outer slice after creating return slice
                            if (values) |vals| {
                                for (vals) |s| self.allocator.free(s);
                                self.allocator.free(vals);
                            }
                        }

                        if (values.?.len == 0) {
                            ret_slice = try self.allocator.dupe(u8, "");
                        } else if (values.?.len == 1) {
                            ret_slice = try self.allocator.dupe(u8, values.?[0]);
                        } else {
                            var result = std.ArrayList(u8).empty;
                            defer result.deinit(self.allocator);
                            for (values.?, 0..) |value, i| {
                                if (i > 0) try result.appendSlice(self.allocator, ", ");
                                try result.appendSlice(self.allocator, value);
                            }
                            ret_slice = try result.toOwnedSlice(self.allocator);
                        }
                        return ret_slice;
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
                .hasValue = struct {
                    fn hasValue(ptr: *anyopaque) bool {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        return self.value != null;
                    }
                }.hasValue,
                .getName = struct {
                    fn getName(ptr: *anyopaque) ?[]const u8 {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        return self.getName();
                    }
                }.getName,
                .getShort = struct {
                    fn getShort(ptr: *anyopaque) ?u8 {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        return self.getShort();
                    }
                }.getShort,
                .getArity = struct {
                    fn getArity(ptr: *anyopaque) Arity {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        return self.getArity();
                    }
                }.getArity,
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
            .ptr = option_ptr,
            .vtable = &Vtable.vtable,
        };
    }

    /// Get the description of the option
    pub fn getDescription(self: Self) []const u8 {
        return self.vtable.getDescription(self.ptr);
    }

    /// Get the default value as a string, returns null if no default is set
    pub fn getDefaultValueAsString(self: Self) !?[]u8 {
        return self.vtable.getDefaultValueAsString(self.ptr);
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
    pub fn getName(self: Self) ?[]const u8 {
        return self.vtable.getName(self.ptr);
    }

    /// Get the short name of the option
    pub fn getShort(self: Self) ?u8 {
        return self.vtable.getShort(self.ptr);
    }

    /// Get the arity of the option
    pub fn getArity(self: Self) Arity {
        return self.vtable.getArity(self.ptr);
    }

    /// Check if the option has a default value
    pub fn hasDefault(self: Self) bool {
        return self.vtable.hasDefault(self.ptr);
    }

    /// Get the type name as a string
    pub fn getTypeName(self: Self) []const u8 {
        return self.vtable.type_name;
    }

    /// Check if the option is of a specific type by comparing type names
    pub fn isType(self: Self, comptime T: type) bool {
        return std.mem.eql(u8, self.vtable.type_name, @typeName(T));
    }
};
