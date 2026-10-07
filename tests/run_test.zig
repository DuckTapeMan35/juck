const std = @import("std");
const modules = @import("modules");
const harness = @import("harness.zig");

const io = std.testing.io;

const Outcome = union(enum) { ok, failed_early, runtime_error };

/// Loads, checks and runs a program, writing its output to `out`.
fn run_program(alloc: std.mem.Allocator, name: []const u8, src: []const u8, out: *std.Io.Writer, max_call_depth: u32) !struct { Outcome, *modules.Program } {
    const p = try modules.Program.create(alloc, io, out);
    p.interpreter.options.max_call_depth = max_call_depth;
    _ = p.load_root(name, src) catch |err| switch (err) {
        error.SyntaxError, error.ImportFailed, error.AnalysisFailed => return .{ .failed_early, p },
        else => return err,
    };
    p.check() catch |err| switch (err) {
        error.TypeError => return .{ .failed_early, p },
        else => return err,
    };
    p.run() catch |err| switch (err) {
        error.RuntimeError => return .{ .runtime_error, p },
        else => return err,
    };
    return .{ .ok, p };
}

test "programs print the expected output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var failures: usize = 0;
    for (try harness.juck_files(alloc, "tests/run")) |file| {
        const stem = file.name[0 .. file.name.len - ".juck".len];
        const expected = std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(alloc, "tests/run/{s}.out", .{stem}), alloc, .limited(1 << 24)) catch {
            std.debug.print("FAIL run/{s}: missing tests/run/{s}.out\n", .{ file.name, stem });
            failures += 1;
            continue;
        };

        var output: std.Io.Writer.Allocating = .init(alloc);
        const outcome, const p = try run_program(alloc, try std.fmt.allocPrint(alloc, "tests/run/{s}", .{file.name}), file.src, &output.writer, 10_000);
        if (outcome != .ok) {
            std.debug.print("FAIL run/{s}: {f}\n", .{ file.name, p.diag });
            failures += 1;
            continue;
        }
        if (!std.mem.eql(u8, expected, output.written())) {
            std.debug.print("FAIL run/{s}: output differs\n--- expected\n{s}--- got\n{s}---\n", .{ file.name, expected, output.written() });
            failures += 1;
        }
    }
    try std.testing.expectEqual(0, failures);
}

test "runtime errors are reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var failures: usize = 0;
    for (try harness.juck_files(alloc, "tests/runtime_errors")) |file| {
        var output: std.Io.Writer.Allocating = .init(alloc);
        // A low limit keeps the deep-recursion test fast.
        const outcome, const p = try run_program(alloc, try std.fmt.allocPrint(alloc, "tests/runtime_errors/{s}", .{file.name}), file.src, &output.writer, 1000);
        switch (outcome) {
            .runtime_error => {},
            .ok => {
                std.debug.print("FAIL runtime_errors/{s}: ran without errors\n", .{file.name});
                failures += 1;
                continue;
            },
            .failed_early => {
                std.debug.print("FAIL runtime_errors/{s}: failed before running: {f}\n", .{ file.name, p.diag });
                failures += 1;
                continue;
            },
        }
        if (harness.expected_error(file.src)) |want| {
            if (want.line != p.diag.line or want.column != p.diag.column) {
                std.debug.print("FAIL runtime_errors/{s}: expected error at {d}:{d}, got {f}\n", .{ file.name, want.line, want.column, p.diag });
                failures += 1;
            }
        }
    }
    try std.testing.expectEqual(0, failures);
}
