# cli-parser

A flexible and type-safe command-line argument parser for Zig applications. Easily build CLI tools with support for commands, subcommands, options, flags, and arguments.

## Features

- **Type-safe parsing**: Options and arguments are type-checked at compile time
- **Subcommands**: Build complex CLI applications with nested command structures
- **Flexible options**: Support for named options with short flags (`-i`, `--int`)
- **Boolean flags**: Simple on/off switches with optional short names
- **Arguments**: Positional arguments with type validation
- **JSON parsing**: Parse complex struct types from command-line input
- **Default values**: Set sensible defaults for options

## Usage

### Basic Example

```zig
const std = @import("std");
const parser = @import("parser");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create an integer option
    var int_opt = try parser.Option(i32).init("An integer option", allocator);
    defer int_opt.deinit();
    _ = int_opt.withName("count")
        .withShort('c')
        .withDefault(10);

    // Create a string argument
    var input_arg = try parser.Argument([]const u8).init("input", "Input file path", false, allocator);
    defer input_arg.deinit();

    // Create a verbose flag
    var verbose_flag = try parser.Flag.init("Enable verbose output", false, allocator);
    _ = verbose_flag.withName("verbose").withShort('v');

    // Define action function
    const action: parser.ActionFn = struct {
        fn call(context: parser.ActionContext) anyerror!void {
            const count = context.getOption(i32, "count") orelse 10;
            const verbose = context.getFlag("verbose");
            const input = context.getArgument([]const u8, 0) orelse "no input";

            std.debug.print("Processing {s} with count {d}\n", .{ input, count });
            if (verbose) {
                std.debug.print("Verbose mode enabled\n", .{});
            }
        }
    }.call;

    // Create command
    const cmd = try parser.Command.init("myapp", "My CLI application", allocator);
    defer cmd.deinit();

    // Register components
    _ = try cmd.withOption(i32, int_opt);
    _ = try cmd.withArgument([]const u8, input_arg);
    _ = try cmd.withFlag(verbose_flag);
    _ = cmd.withAction(action);

    // Parse and execute
    var cli_parser = parser.Parser.init(cmd, allocator);
    var result = try cli_parser.parseWithContext();
    defer result.context.deinit();

    try result.command.execute(result.context);
}
```

### Subcommands Example

```zig
// Create main command
const main_cmd = try parser.Command.init("myapp", "My application", allocator);
defer main_cmd.deinit();

// Create subcommand
const sub_cmd = try parser.Command.init("process", "Process data", allocator);
defer sub_cmd.deinit();

// Add options/flags to subcommand
// ... (add options, arguments, flags, action)

// Register subcommand
_ = try main_cmd.withSubcommand(sub_cmd);
```

### Complex Types

The parser supports parsing complex struct types from JSON:

```zig
const Config = struct {
    host: []const u8,
    port: u16,
};

var config_opt = try parser.Option(Config).init("Server configuration", allocator);
defer config_opt.deinit();
_ = config_opt.withName("config").withShort('c');

// Usage: myapp --config '{"host":"localhost","port":8080}'
```

## How to Import

Add cli-parser to your project using `zig fetch`:

```bash
zig fetch --save git+https://github.com/arnon4/cli-parser
```

Then add it to your `build.zig`:

```zig
const parser_dep = b.dependency("cli-parser", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("parser", parser_dep.module("parser"));
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
