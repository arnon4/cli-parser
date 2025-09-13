pub const OptConfig = @This();
type: type,
/// The long name of the option. Either `long_name` or `short_name` must be provided.
long_name: ?[]const u8 = null,
/// The short name of the option. Either `long_name` or `short_name` must be provided.
short_name: ?u8 = null,
/// The description of the option (for help text).
description: []const u8,
