const std = @import("std");

/// Arity defines how many values an argument or option can take.
pub const Arity = struct {
    const Self = @This();

    min: u8,
    max: u8,

    pub fn init(min: u8, max: u8) Self {
        if (min > max) {
            @panic("min cannot be greater than max");
        }
        return Self{
            .min = min,
            .max = max,
        };
    }

    /// An arity that allows zero values.
    pub const zero: Self = Self.init(0, 0);
    /// An arity that allows zero or one value.
    pub const zero_or_one: Self = Self.init(0, 1);
    /// An arity that requires zero or more values.
    pub const zero_or_more: Self = Self.init(0, std.math.maxInt(u8));
    /// An arity that requires exactly one value.
    pub const exactly_one: Self = Self.init(1, 1);
    /// An arity that requires one or more values.
    pub const one_or_more: Self = Self.init(1, std.math.maxInt(u8));
    /// An arity that allows many values (up to the maximum of u8).
    pub const many: Self = Self.init(std.math.maxInt(u8), std.math.maxInt(u8));
};
