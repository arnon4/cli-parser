pub const ArgConfig = @This();
type: type,
/// The name of the argument.
name: []const u8,
/// The description of the argument (for help text).
description: []const u8,
/// Whether the argument is required.
required: bool = false,
