const std = @import("std");
const reader = @import("reader");
const printer = @import("printer");
const harness = @import("harness");

const io = std.testing.io;

test "valid files parse" {
    var failures: usize = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var dir = try std.Io.Dir.cwd().openDir(io, "tests/valid", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".juck")) continue;
        const src = try dir.readFileAlloc(io, entry.name, alloc, .limited(1 << 24));

        var diag: reader.Diagnostic = undefined;
        const program = reader.read(src, alloc, &diag) catch {
            std.debug.print("FAIL valid/{s}: syntax error at {d}:{d}\n", .{ entry.name, diag.line, diag.column });
            failures += 1;
            continue;
        };
        var json: std.Io.Writer.Allocating = .init(alloc);
        try printer.write_json(&json.writer, program);
        _ = std.json.parseFromSliceLeaky(std.json.Value, alloc, json.written(), .{}) catch |err| {
            std.debug.print("FAIL valid/{s}: --json output is not valid JSON ({t})\n", .{ entry.name, err });
            failures += 1;
        };
    }
    try std.testing.expectEqual(0, failures);
}

test "invalid files are rejected" {
    var failures: usize = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var dir = try std.Io.Dir.cwd().openDir(io, "tests/invalid", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".juck")) continue;
        const src = try dir.readFileAlloc(io, entry.name, alloc, .limited(1 << 24));

        var diag: reader.Diagnostic = undefined;
        if (reader.read(src, alloc, &diag)) |_| {
            std.debug.print("FAIL invalid/{s}: parsed without errors\n", .{entry.name});
            failures += 1;
            continue;
        } else |_| {}

        if (harness.expected_error(src)) |want| {
            if (want.line != diag.line or want.column != diag.column) {
                std.debug.print("FAIL invalid/{s}: expected error at {d}:{d}, got {d}:{d}\n", .{
                    entry.name, want.line, want.column, diag.line, diag.column,
                });
                failures += 1;
            }
        }
    }
    try std.testing.expectEqual(0, failures);
}
