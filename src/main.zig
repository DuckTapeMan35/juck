const std = @import("std");
const Io = std.Io;
const lexer = @import("lexer");
const reader = @import("reader");
const printer = @import("printer");
const repl = @import("repl");
const unparse = @import("unparse");
const modules = @import("modules");
const stdlib = @import("stdlib");

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

const Mode = enum { run, repl, check, tokens, ast, json, expand };

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

    const src = try read_source(init.io, alloc, file);

    if (mode == .tokens) {
        // lex() consumes the slice it's given and needs it mutable, so
        // hand it a copy (the source may be an embedded std module).
        var rest = try alloc.dupe(u8, src);
        const tokens = try lexer.lex(&rest, alloc);
        for (tokens) |t| try out.print("{f}\n", .{t});
        return;
    }

    switch (mode) {
        .run, .check, .expand => {
            // In --expand, output from print in macro bodies goes to
            // stderr, so stdout is only the expanded program.
            var stderr_buf: [4096]u8 = undefined;
            var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
            defer stderr_writer.interface.flush() catch {};
            const program = try modules.Program.create(alloc, init.io, if (mode == .expand) &stderr_writer.interface else out);

            const root = program.load_root(file, src) catch |err| return report(program, err);
            if (mode == .expand) {
                return printer.write_json(out, try unparse.program(alloc, root.program, try program.root_aliases()));
            }
            program.check() catch |err| return report(program, err);
            if (mode == .run) program.run() catch |err| return report(program, err);
        },
        .repl => try repl.run(init.io, alloc, out, .{ .name = file, .src = src }),
        .tokens => {},
        .ast => try printer.write_tree(out, try reader.read(src, alloc, null), 0),
        .json => try printer.write_json(out, try reader.read(src, alloc, null)),
    }
}

/// The contents of a file, or of a standard library module: std/logic
/// (with or without .juck) is the embedded module, unless a file by that name exists
fn read_source(io: Io, alloc: std.mem.Allocator, file: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, file, alloc, .limited(16 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound and std.mem.startsWith(u8, file, "std/")) {
            const path = if (std.mem.endsWith(u8, file, ".juck")) file[0 .. file.len - ".juck".len] else file;
            if (stdlib.get(path)) |embedded| return embedded;
        }
        return err;
    };
}

/// Prints a program's error, if it is one juck reports, and returns
/// error.Reported so main exits without printing it again. (Returning,
/// instead of exiting here, lets the program's output be flushed first.)
fn report(program: *modules.Program, err: anyerror) anyerror {
    switch (err) {
        error.SyntaxError, error.ImportFailed, error.AnalysisFailed, error.TypeError, error.RuntimeError => {
            std.debug.print("{f}\n", .{program.diag});
            return error.Reported;
        },
        else => return err,
    }
}

pub fn main(init: std.process.Init) !void {
    main_impl(init) catch |err| {
        if (err != error.Reported) std.debug.print("Fatal error: {}\n", .{err});
        std.process.exit(1);
    };
}
