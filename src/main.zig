const std = @import("std");
const Io = std.Io;
const lexer = @import("lexer");
const reader = @import("reader");
const printer = @import("printer");
const analyzer = @import("analyzer");
const checker = @import("checker");
const interpreter = @import("interpreter");
const repl = @import("repl");

const usage =
    \\usage: juck [<file>] [--repl | --check | --tokens | --ast | --json]
    \\
    \\  (no file)  start the REPL
    \\  (no flag)  run the program
    \\  --repl     run the program, then start the REPL with its definitions
    \\  --check    check the program for errors without running it
    \\  --tokens   print the lexer's tokens
    \\  --ast      print the syntax tree
    \\  --json     print the program as strict JSON
    \\
;

const Mode = enum { run, repl, check, tokens, ast, json };

fn main_impl(init: std.process.Init) !void {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    var arena = std.heap.ArenaAllocator.init(da.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try init.minimal.args.toSlice(alloc);
    var path: ?[]const u8 = null;
    var mode: Mode = .run;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--repl")) {
            mode = .repl;
        } else if (std.mem.eql(u8, arg, "--check")) {
            mode = .check;
        } else if (std.mem.eql(u8, arg, "--tokens")) {
            mode = .tokens;
        } else if (std.mem.eql(u8, arg, "--ast")) {
            mode = .ast;
        } else if (std.mem.eql(u8, arg, "--json")) {
            mode = .json;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("unknown flag '{s}'\n\n{s}", .{ arg, usage });
            return error.InvalidArgs;
        } else {
            path = arg;
        }
    }
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(init.io, &stdout_buf);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};
    const file = path orelse {
        if (mode == .run or mode == .repl) return repl.run(init.io, alloc, out, null);
        std.debug.print("{s}", .{usage});
        return error.InvalidArgs;
    };

    const src = try Io.Dir.cwd().readFileAlloc(init.io, file, alloc, .limited(16 * 1024 * 1024));

    if (mode == .tokens) {
        // lex() consumes the slice it's given, so hand it a copy of the slice
        // (not of the bytes); src itself stays intact.
        var rest = src;
        const tokens = try lexer.lex(&rest, alloc);
        for (tokens) |t| try out.print("{f}\n", .{t});
        return;
    }

    const program = try reader.read(src, alloc, null);
    switch (mode) {
        .repl => {
            const analyzed = try analyzer.analyze(src, program, alloc, null);
            try repl.run(init.io, alloc, out, .{ .src = src, .program = analyzed });
        },
        .run, .check => {
            const analyzed = try analyzer.analyze(src, program, alloc, null);
            try checker.check(src, analyzed, alloc, null);
            if (mode == .run) try interpreter.run(src, analyzed, alloc, out, null, .{});
        },
        .tokens => {},
        .ast => try printer.write_tree(out, program, 0),
        .json => try printer.write_json(out, program),
    }
}

pub fn main(init: std.process.Init) !void {
    main_impl(init) catch |err| {
        std.debug.print("Fatal error: {}\n", .{err});
        std.process.exit(1);
    };
}
