const std = @import("std");

/// Arity defines how many values an argument or option can take.
pub const Arity = struct {
    const Self = @This();

    min: usize,
    max: usize,

    /// An arity that allows zero values.
    pub const zero = Self{
        .min = 0,
        .max = 0,
    };
    /// An arity that allows zero or one value.
    pub const zero_or_one = Self{
        .min = 0,
        .max = 1,
    };
    /// An arity that requires zero or more values.
    pub const zero_or_more = Self{
        .min = 0,
        .max = std.math.maxInt(u8),
    };
    /// An arity that requires exactly one value.
    pub const exactly_one = Self{
        .min = 1,
        .max = 1,
    };
    /// An arity that requires one or more values.
    pub const one_or_more = Self{
        .min = 1,
        .max = std.math.maxInt(u8),
    };
};
