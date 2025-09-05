const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
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
        value: ArrayList([]const u8) = .empty,

        pub fn asString(self: ParsedValue, index: usize) []const u8 {
            std.debug.assert(index < self.value.items.len);
            return self.value.items[index];
        }

        pub fn asInt(self: ParsedValue, comptime T: type, index: usize) ActionError!T {
            return try std.fmt.parseInt(T, self.value.items[index], 10);
        }

        pub fn asFloat(self: ParsedValue, comptime T: type, index: usize) ActionError!T {
            return try std.fmt.parseFloat(T, self.value.items[index]);
        }

        pub fn asBool(self: ParsedValue, index: usize) bool {
            return std.mem.eql(u8, self.value.items[index], "true") or std.mem.eql(u8, self.value.items[index], "1");
        }

        pub fn asStruct(self: ParsedValue, comptime T: type, allocator: Allocator, index: usize) ActionError!std.json.Parsed(T) {
            return try std.json.parseFromSlice(T, allocator, self.value.items[index], .{});
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
        // Free all owned strings in options (each entry is an ArrayList of slices)
        var option_iter = self.options.iterator();
        while (option_iter.next()) |entry| {
            for (entry.value_ptr.*.value.items) |s| self.allocator.free(s);
            entry.value_ptr.*.value.deinit(self.allocator);
        }
        self.options.deinit();

        self.flags.deinit();

        // Free all owned strings in arguments
        var arg_iter = self.arguments.iterator();
        while (arg_iter.next()) |entry| {
            for (entry.value_ptr.*.value.items) |s| self.allocator.free(s);
            entry.value_ptr.*.value.deinit(self.allocator);
        }
        self.arguments.deinit();

        // Free the allocated ActionContext itself
        self.allocator.destroy(self);
        if (self.parent) |p| {
            p.child = null;
            p.deinit();
        }
    }

    /// Set an option value.
    pub fn setOption(self: *Self, name: []const u8, value: ParsedValue) !void {
        try self.options.put(name, value);
    }

    /// Set a flag value.
    pub fn setFlag(self: *Self, name: []const u8, value: bool) !void {
        try self.flags.put(name, value);
    }

    /// Set an argument value.
    pub fn setArgument(self: *Self, name: []const u8, value: ParsedValue) !void {
        try self.arguments.put(name, value);
    }

    /// Get an option value by name and type. If the option has multiple values, the first one is returned.
    pub fn getOption(self: *const Self, comptime T: type, name: []const u8) !T {
        if (self.options.get(name)) |value| {
            const requested_type = @typeInfo(T);
            switch (requested_type) {
                .int => return value.asInt(T, 0),
                .float => return value.asFloat(T, 0),
                .bool => return value.asBool(0),
                .pointer => |ptr_info| {
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        return value.asString(0);
                    } else {
                        return ActionError.InvalidType;
                    }
                },
                .array => return value.asString(0),
                .@"struct" => {
                    const parsed = try value.asStruct(T, self.allocator, 0);
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

    /// Get an option value by name and type.
    fn getOptionByIndex(self: *const Self, comptime T: type, name: []const u8, index: usize) !T {
        if (self.options.get(name)) |value| {
            const requested_type = @typeInfo(T);
            switch (requested_type) {
                .int => return value.asInt(T, index),
                .float => return value.asFloat(T, index),
                .bool => return value.asBool(index),
                .pointer => |ptr_info| {
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        return value.asString(index);
                    } else {
                        return ActionError.InvalidType;
                    }
                },
                .array => return value.asString(index),
                .@"struct" => {
                    const parsed = try value.asStruct(T, self.allocator, index);
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

    pub fn getOptions(self: *const Self, comptime T: type, name: []const u8, buffer: []T) !void {
        if (self.options.get(name)) |value| {
            std.debug.assert(buffer.len >= value.value.items.len);

            for (value.value.items, 0..) |_, i| {
                const parsed_opt = try self.getOptionByIndex(T, name, i);
                buffer[i] = parsed_opt;
            }

            return;
        }

        if (self.parent) |parent| {
            return parent.getOptions(T, name, buffer);
        }

        return ActionError.OptionNotFound;
    }

    /// Get a flag value by name.
    pub fn getFlag(self: *const Self, name: []const u8) bool {
        if (self.flags.get(name)) |value| {
            return value;
        } else if (self.parent) |parent| {
            return parent.getFlag(name);
        }

        return false;
    }

    /// Get an argument value by name and type. If the argument has multiple values, the first one is returned.
    pub fn getArgument(self: *const Self, comptime T: type, name: []const u8) !T {
        if (self.arguments.get(name)) |value| {
            const requested_type = @typeInfo(T);
            switch (requested_type) {
                .int => return value.asInt(T, 0),
                .float => return value.asFloat(T, 0),
                .bool => return value.asBool(0),
                .pointer => |ptr_info| {
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        return value.asString(0);
                    } else {
                        return ActionError.InvalidType;
                    }
                },
                .array => return value.asString(0),
                .@"struct" => {
                    const parsed = try value.asStruct(T, self.allocator, 0);
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

    /// Get an argument value by name and type.
    fn getArgumentByIndex(self: *const Self, comptime T: type, name: []const u8, index: usize) !T {
        if (self.arguments.get(name)) |value| {
            const requested_type = @typeInfo(T);
            switch (requested_type) {
                .int => return value.asInt(T, index),
                .float => return value.asFloat(T, index),
                .bool => return value.asBool(index),
                .pointer => |ptr_info| {
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        return value.asString(index);
                    } else {
                        return ActionError.InvalidType;
                    }
                },
                .array => return value.asString(index),
                .@"struct" => {
                    const parsed = try value.asStruct(T, self.allocator, index);
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

    /// Get all argument values by name and type.
    pub fn getArguments(self: *const Self, comptime T: type, name: []const u8, buffer: []T) !void {
        if (self.arguments.get(name)) |value| {
            std.debug.assert(buffer.len >= value.value.items.len);

            for (value.value.items, 0..) |_, i| {
                const parsed_arg = try self.getArgumentByIndex(T, name, i);
                buffer[i] = parsed_arg;
            }

            return;
        }

        if (self.parent) |parent| {
            return parent.getArguments(T, name, buffer);
        }

        return ActionError.ArgumentNotFound;
    }
};
