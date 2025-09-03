# cli-parser

A flexible and type-safe command-line argument parser for Zig applications. Build rich CLI tools with nested commands, typed options/arguments, flags, JSON-typed values, and defaults.

## Features

* Type-safe parsing (generic `Option(T)` / `Argument(T)` constructors)
* Nested commands / subcommands with inherited context
* Short & long options (`-i`, `--int`), boolean flags, positional arguments
* JSON parsing for struct types (e.g. `--worker '{"name":"A","id":1}'`)
* Arity support and default values (single or multiple)

## Usage

### Basic Example

```zig
const std = @import("std");
const parser = @import("parser");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Integer option (single default value)
    var count_opt = try parser.Option(i32).init("Number of repetitions", allocator);
    defer count_opt.deinit();
    _ = count_opt.withName("count")
        .withShort('c')
        .withDefaultValue(10);

    // String argument (optional)
    var input_arg = try parser.Argument([]const u8).init("input", "Input file path", false, allocator);
    defer input_arg.deinit();

    // Create a verbose flag
    var verbose_flag = try parser.Flag.init("Enable verbose output", false, allocator);
    _ = verbose_flag.withName("verbose").withShort('v');

    // Define action function
    const action: parser.ActionFn = struct {
        fn call(context: parser.ActionContext) anyerror!void {
            const count = context.getOption(i32, "count") catch 10; // default already set
            const verbose = context.getFlag("verbose");
            const input = context.getArgument([]const u8, "input") catch "no input";

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
    _ = cmd.withOption(i32, count_opt)
        .withArgument([]const u8, input_arg)
        .withFlag(verbose_flag)
        .withAction(action);

    // Parse and execute
    var cli_parser = parser.Parser.init(cmd, allocator);
    defer cli_parser.deinit();
    const result = try cli_parser.parse();
    try result.invoke();
}
```

### Subcommands Example

```zig
// Create main command
const main_cmd = try parser.Command.init("myapp", "My application", allocator);
defer main_cmd.deinit();

const sub_cmd = try parser.Command.init("process", "Process data", allocator);
defer sub_cmd.deinit();

// Example option on subcommand
var jobs_opt = try parser.Option(i32).init("Jobs to spawn", allocator);
defer jobs_opt.deinit();
_ = jobs_opt.withName("jobs").withShort('j').withDefaultValue(4);

_ = sub_cmd.withOption(i32, jobs_opt)
    .withAction(struct {
        fn call(ctx: parser.ActionContext) !void {
            const jobs = ctx.getOption(i32, "jobs") catch 4;
            std.debug.print("Processing with {d} jobs\n", .{jobs});
        }
    }.call);

_ = main_cmd.withSubcommand(sub_cmd);
```

### Complex Types (JSON)

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

### Multiple / Single Values & Arity

Use `withArity` to change allowed counts. Example for an option that can take multiple integers:

```zig
var nums_opt = try parser.Option(i32).init("Numbers", allocator);
defer nums_opt.deinit();
_ = nums_opt.withName("num").withArity(.{ .min = 1, .max = 3 })
    .withDefaultValues(&[_]i32{ 1, 2 }); // plural setter

// For single-value only (arity max <= 1):
_ = nums_opt.withArity(.zero_or_one).withDefaultValue(5); // singular setter
```

### How to Import

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
