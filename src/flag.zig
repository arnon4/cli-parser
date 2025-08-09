const std = @import("std");
const testing = std.testing;

/// Flag represents a boolean command-line flag
pub const Flag = struct {
    const Self = @This();

    name: ?[]const u8 = null,
    short: ?u8 = null,
    description: []const u8,
    default_value: bool,
    value: ?bool = null,
    allocator: std.mem.Allocator,

    /// Initialize a flag
    pub fn init(description: []const u8, default_value: bool, allocator: std.mem.Allocator) !*Self {
        const flag = try allocator.create(Self);
        flag.* = Self{
            .description = description,
            .default_value = default_value,
            .allocator = allocator,
        };
        return flag;
    }

    /// Deinitialize the flag
    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    /// Set the long name for the flag (e.g., "verbose")
    pub fn withName(self: *Self, name: []const u8) *Self {
        self.name = name;
        return self;
    }

    /// Set the short name for the flag (e.g., 'v')
    pub fn withShort(self: *Self, short: u8) *Self {
        self.short = short;
        return self;
    }

    /// Get the current value of the flag (returns flipped default if flag was provided)
    pub fn getValue(self: *const Self) bool {
        if (self.value) |v| {
            return v;
        }
        return self.default_value;
    }

    /// Get the long name of the flag
    pub fn getName(self: *const Self) ?[]const u8 {
        return self.name;
    }

    /// Get the short name of the flag
    pub fn getShort(self: *const Self) ?u8 {
        return self.short;
    }

    /// Set the flag (flips the default value)
    pub fn setFlag(self: *Self) void {
        self.value = !self.default_value;
    }

    /// Reset the flag to its default value
    pub fn reset(self: *Self) void {
        self.value = null;
    }

    /// Check if the flag was explicitly set (vs using default)
    pub fn isSet(self: *const Self) bool {
        return self.value != null;
    }

    /// Get the description of the flag
    pub fn getDescription(self: *const Self) []const u8 {
        return self.description;
    }
};
