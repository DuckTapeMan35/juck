const std = @import("std");
const Io = std.Io;
const lexer = @import("lexer");
const reader = @import("reader");
const printer = @import("printer");

const usage =
    \\usage: juck <file> [--tokens | --ast | --json]
    \\
    \\  (no flag)  check the file for syntax errors
    \\  --tokens   print the lexer's tokens
    \\  --ast      print the syntax tree
    \\  --json     print the program as strict JSON
    \\
;

const Mode = enum { check, tokens, ast, json };

fn mainImpl(init: std.process.Init) !void {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    var arena = std.heap.ArenaAllocator.init(da.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try init.minimal.args.toSlice(alloc);
    var path: ?[]const u8 = null;
    var mode: Mode = .check;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--tokens")) {
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
    const file = path orelse {
        std.debug.print("{s}", .{usage});
        return error.InvalidArgs;
    };

    const src = try Io.Dir.cwd().readFileAlloc(init.io, file, alloc, .limited(16 * 1024 * 1024));

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(init.io, &stdout_buf);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    if (mode == .tokens) {
        // lex() consumes the slice it's given, so hand it a copy of the slice
        // (not of the bytes); src itself stays intact.
        var rest = src;
        const tokens = try lexer.lex(&rest, alloc);
        for (tokens) |t| try out.print("{f}\n", .{t});
        return;
    }

    const forms = try reader.read(src, alloc, null);
    switch (mode) {
        .check, .tokens => {},
        .ast => for (forms) |form| try printer.writeTree(out, form, 0),
        .json => try printer.writeJson(out, forms),
    }
}

pub fn main(init: std.process.Init) !void {
    mainImpl(init) catch |err| {
        std.debug.print("Fatal error: {}\n", .{err});
        std.process.exit(1);
    };
}
