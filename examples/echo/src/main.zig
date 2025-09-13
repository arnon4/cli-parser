const std = @import("std");

const Argument = @import("parser").Argument;
const ArgConfig = @import("parser").ArgConfig;
const ActionContext = @import("parser").ActionContext;
const ActionFn = @import("parser").ActionFn;
const Command = @import("parser").Command;
const Flag = @import("parser").Flag;
const Option = @import("parser").Option;
const OptConfig = @import("parser").OptConfig;
const Parser = @import("parser").Parser;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const newline_flag = try Flag.init("Print a newline after the message", false, allocator);
    _ = newline_flag
        .withShort('n');

    const enable_escape_flag = try Flag.init("Enable interpretation of backslash escapes", false, allocator);
    _ = enable_escape_flag
        .withShort('e');

    const input_args_config = ArgConfig{
        .type = []const u8,
        .name = "strings",
        .description = "Strings to echo",
        .required = false,
    };
    var input_args = try Argument(input_args_config).init(allocator);
    _ = input_args.withArity(.{
        .min = 0,
        .max = 255,
    });

    const action: ActionFn = struct {
        fn hexToBinary(char: u8) u8 {
            return switch (char) {
                'a', 'A' => 10,
                'b', 'B' => 11,
                'c', 'C' => 12,
                'd', 'D' => 13,
                'e', 'E' => 14,
                'f', 'F' => 15,
                else => char - '0',
            };
        }

        fn call(ctx: ActionContext) !void {
            const newline = ctx.getFlag("n");
            const enable_escape = ctx.getFlag("e");

            var first = true;
            var args_buf: [256][]const u8 = undefined;
            const count = ctx.getArguments([]const u8, "strings", &args_buf) catch 0;

            for (0..count) |i| {
                if (!first) {
                    std.debug.print(" ", .{});
                }
                first = false;

                const arg = args_buf[i];

                if (!enable_escape) {
                    std.debug.print("{s}", .{arg});
                } else {
                    var j: usize = 0;
                    while (j < arg.len) {
                        var char: u8 = arg[j];
                        if (char == '\\' and j + 1 < arg.len) {
                            j += 1;
                            switch (arg[j]) {
                                'a' => char = 7, // alert (bell)
                                'b' => char = 8, // backspace
                                'c' => return, // suppress further output
                                'e', 'E' => char = 27, // escape character
                                'f' => char = 12, // form feed
                                'n' => char = 10, // new line
                                'r' => char = 13, // carriage return
                                't' => char = 9, // horizontal tab
                                'v' => char = 11, // vertical tab
                                '\\' => char = '\\', // backslash
                                'x' => {
                                    // Hexadecimal escape sequence \xHH
                                    if (j + 1 < arg.len and std.ascii.isHex(arg[j + 1])) {
                                        char = hexToBinary(arg[j + 1]);
                                        j += 1;
                                        if (j + 1 < arg.len and std.ascii.isHex(arg[j + 1])) {
                                            char = char * 16 + hexToBinary(arg[j + 1]);
                                            j += 1;
                                        }
                                    } else {
                                        // Invalid hex sequence, print as literal
                                        std.debug.print("\\x", .{});
                                        continue;
                                    }
                                },
                                '0' => {
                                    // Octal escape sequence \0nnn
                                    char = 0;
                                    if (j + 1 < arg.len and arg[j + 1] >= '0' and arg[j + 1] <= '7') {
                                        j += 1;
                                        char = arg[j] - '0';
                                        if (j + 1 < arg.len and arg[j + 1] >= '0' and arg[j + 1] <= '7') {
                                            j += 1;
                                            char = char * 8 + arg[j] - '0';
                                            if (j + 1 < arg.len and arg[j + 1] >= '0' and arg[j + 1] <= '7') {
                                                j += 1;
                                                char = char * 8 + arg[j] - '0';
                                            }
                                        }
                                    }
                                },
                                'u' => {
                                    // Unicode escape sequence \uHHHH
                                    var utf8: u21 = 0;
                                    var hex_count: usize = 0;
                                    while (hex_count < 4 and j + 1 < arg.len and std.ascii.isHex(arg[j + 1])) {
                                        j += 1;
                                        utf8 = utf8 * 16 + hexToBinary(arg[j]);
                                        hex_count += 1;
                                    }
                                    if (hex_count > 0) {
                                        std.debug.print("{u}", .{utf8});
                                        j += 1;
                                        continue;
                                    } else {
                                        // Invalid unicode sequence, print as literal
                                        std.debug.print("\\u", .{});
                                        continue;
                                    }
                                },
                                'U' => {
                                    // Unicode escape sequence \UHHHHHHHH
                                    var utf8: u21 = 0;
                                    var hex_count: usize = 0;
                                    while (hex_count < 8 and j + 1 < arg.len and std.ascii.isHex(arg[j + 1])) {
                                        j += 1;
                                        utf8 = utf8 * 16 + hexToBinary(arg[j]);
                                        hex_count += 1;
                                    }
                                    if (hex_count > 0) {
                                        if (utf8 > 0x10FFFF) {
                                            // Invalid Unicode code point, print nothing
                                        } else {
                                            std.debug.print("{u}", .{utf8});
                                        }
                                        j += 1;
                                        continue;
                                    } else {
                                        // Invalid unicode sequence, print as literal
                                        std.debug.print("\\U", .{});
                                        continue;
                                    }
                                },
                                else => {
                                    // Unknown escape sequence, print backslash and character literally
                                    std.debug.print("\\{c}", .{arg[j]});
                                    j += 1;
                                    continue;
                                },
                            }
                        }
                        std.debug.print("{c}", .{char});
                        j += 1;
                    }
                }
            }

            if (!newline) {
                std.debug.print("\n", .{});
            }
        }
    }.call;

    const cmd = try Command.init("echo", "Echo the input arguments", allocator);

    _ = cmd.withFlag(newline_flag)
        .withFlag(enable_escape_flag)
        .withArgument(input_args_config, input_args)
        .withAction(action);

    var parser = Parser(.{
        .allow_unknown_options = false,
        .double_hyphen_delimiter = true,
        .allow_options_after_args = false,
    }).init(cmd, allocator);

    const result = try parser.parse();

    try result.invoke();
}
