const std = @import("std");
const modules = @import("modules");
const harness = @import("harness.zig");

const Stage = enum { analysis, checking, none };

/// Loads and checks `file`; returns the stage that failed, if any.
fn run_stages(alloc: std.mem.Allocator, path: []const u8, file: harness.File, program: **modules.Program) !Stage {
    var output: std.Io.Writer.Allocating = .init(alloc); // `print` in macro bodies
    const p = try modules.Program.create(alloc, std.testing.io, &output.writer);
    program.* = p;
    _ = p.load_root(try std.fmt.allocPrint(alloc, "{s}/{s}", .{ path, file.name }), file.src) catch |err| switch (err) {
        error.SyntaxError, error.ImportFailed, error.AnalysisFailed => return .analysis,
        else => return err,
    };
    p.check() catch |err| switch (err) {
        error.TypeError => return .checking,
        else => return err,
    };
    return .none;
}

fn expect_stage(dir: []const u8, expected: Stage) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var failures: usize = 0;
    const path = try std.fmt.allocPrint(alloc, "tests/{s}", .{dir});
    for (try harness.juck_files(alloc, path)) |file| {
        var program: *modules.Program = undefined;
        const failed = try run_stages(alloc, path, file, &program);
        const d = program.diag;
        if (failed != expected) {
            if (failed == .none) {
                std.debug.print("FAIL {s}/{s}: no error\n", .{ dir, file.name });
            } else {
                std.debug.print("FAIL {s}/{s}: failed in {t}, not {t}: {f}\n", .{ dir, file.name, failed, expected, d });
            }
            failures += 1;
            continue;
        }
        if (harness.expected_error(file.src)) |want| {
            if (want.line != d.line or want.column != d.column) {
                std.debug.print("FAIL {s}/{s}: expected error at {d}:{d}, got {f}\n", .{ dir, file.name, want.line, want.column, d });
                failures += 1;
            }
        }
    }
    try std.testing.expectEqual(0, failures);
}

test "programs analyze and type check" {
    try expect_stage("programs", .none);
}

test "analysis errors are reported" {
    try expect_stage("analysis_errors", .analysis);
}

test "type errors are reported" {
    try expect_stage("type_errors", .checking);
}
