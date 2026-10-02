const std = @import("std");
const Io = std.Io;
const juck = @import("juck");
const lexer = @import("lexer");

fn mainImpl(init: std.process.Init) !void {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    var arena = std.heap.ArenaAllocator.init(da.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);
    var src = try Io.Dir.cwd().readFileAlloc(init.io, args[1], alloc, .limited(16 * 1024 * 1024));

    const tokens = lexer.lex(&src, alloc) catch {
        return error.InvalidInput;
    };
    std.debug.print("{any}", .{tokens});
}

pub fn main(init: std.process.Init) !void {
    mainImpl(init) catch |err| {
        std.debug.print("Fata error: {}\n", .{err});
        std.process.exit(1);
    };
}
