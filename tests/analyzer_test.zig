const std = @import("std");
const reader = @import("reader");
const analyzer = @import("analyzer");
const harness = @import("harness");
const checker = @import("checker");

test "programs analyze" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var failures: usize = 0;
    for (try harness.juck_files(alloc, "tests/programs")) |file| {
        var diag: reader.Diagnostic = undefined;
        const value = reader.read(file.src, alloc, &diag) catch {
            std.debug.print("FAIL programs/{s}: syntax error {d}:{d}: {s}\n", .{ file.name, diag.line, diag.column, diag.message });
            failures += 1;
            continue;
        };
        const analyzed = analyzer.analyze(file.src, value, alloc, &diag) catch {
            std.debug.print("FAIL programs/{s}: {d}:{d}: {s}\n", .{ file.name, diag.line, diag.column, diag.message });
            failures += 1;
            continue;
        };
        checker.check(file.src, analyzed, alloc, &diag) catch {
            std.debug.print("FAIL programs/{s}: type error {d}:{d}: {s}\n", .{ file.name, diag.line, diag.column, diag.message });
            failures += 1;
        };
    }
    try std.testing.expectEqual(0, failures);
}

test "analysis errors are reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var failures: usize = 0;
    for (try harness.juck_files(alloc, "tests/analysis_errors")) |file| {
        var diag: reader.Diagnostic = undefined;
        const value = reader.read(file.src, alloc, &diag) catch {
            std.debug.print("FAIL analysis_errors/{s}: is a syntax error ({d}:{d}: {s}), not an analysis error\n", .{ file.name, diag.line, diag.column, diag.message });
            failures += 1;
            continue;
        };
        if (analyzer.analyze(file.src, value, alloc, &diag)) |_| {
            std.debug.print("FAIL analysis_errors/{s}: analyzed without errors\n", .{file.name});
            failures += 1;
            continue;
        } else |_| {}

        if (harness.expected_error(file.src)) |want| {
            if (want.line != diag.line or want.column != diag.column) {
                std.debug.print("FAIL analysis_errors/{s}: expected error at {d}:{d}, got {d}:{d} ({s})\n", .{
                    file.name, want.line, want.column, diag.line, diag.column, diag.message,
                });
                failures += 1;
            }
        }
    }
    try std.testing.expectEqual(0, failures);
}

test "type errors are reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var failures: usize = 0;
    for (try harness.juck_files(alloc, "tests/type_errors")) |file| {
        var diag: reader.Diagnostic = undefined;
        const value = reader.read(file.src, alloc, &diag) catch {
            std.debug.print("FAIL type_errors/{s}: is a syntax error ({d}:{d}: {s})\n", .{ file.name, diag.line, diag.column, diag.message });
            failures += 1;
            continue;
        };
        const analyzed = analyzer.analyze(file.src, value, alloc, &diag) catch {
            std.debug.print("FAIL type_errors/{s}: fails pass 1 ({d}:{d}: {s}), not type checking\n", .{ file.name, diag.line, diag.column, diag.message });
            failures += 1;
            continue;
        };
        if (checker.check(file.src, analyzed, alloc, &diag)) |_| {
            std.debug.print("FAIL type_errors/{s}: type checked without errors\n", .{file.name});
            failures += 1;
            continue;
        } else |_| {}

        if (harness.expected_error(file.src)) |want| {
            if (want.line != diag.line or want.column != diag.column) {
                std.debug.print("FAIL type_errors/{s}: expected error at {d}:{d}, got {d}:{d} ({s})\n", .{
                    file.name, want.line, want.column, diag.line, diag.column, diag.message,
                });
                failures += 1;
            }
        }
    }
    try std.testing.expectEqual(0, failures);
}
