const std = @import("std");
const reader = @import("reader");
const ast = @import("ast");
const analyzer = @import("analyzer");
const checker = @import("checker");
const interpreter = @import("interpreter");
const macros = @import("macros");
const harness = @import("harness.zig");

const io = std.testing.io;

const Prepared = struct { program: ast.Program, expander: *macros.Expander };

/// Reads, analyzes and checks `src`; reports and returns null on failure.
fn prepare(alloc: std.mem.Allocator, dir: []const u8, file: harness.File, out: *std.Io.Writer) !?Prepared {
    var diag: reader.Diagnostic = undefined;
    const value = reader.read(file.src, alloc, &diag) catch {
        std.debug.print("FAIL {s}/{s}: syntax error {d}:{d}: {s}\n", .{ dir, file.name, diag.line, diag.column, diag.message });
        return null;
    };
    const expander = try alloc.create(macros.Expander);
    expander.* = .init(alloc, out);
    const program = analyzer.analyze(file.src, value, alloc, &diag, expander.options()) catch {
        std.debug.print("FAIL {s}/{s}: {d}:{d}: {s}\n", .{ dir, file.name, diag.line, diag.column, diag.message });
        return null;
    };
    checker.check(file.src, program, alloc, &diag) catch {
        std.debug.print("FAIL {s}/{s}: type error {d}:{d}: {s}\n", .{ dir, file.name, diag.line, diag.column, diag.message });
        return null;
    };
    return .{ .program = program, .expander = expander };
}

test "programs print the expected output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var failures: usize = 0;
    for (try harness.juck_files(alloc, "tests/run")) |file| {
        var output: std.Io.Writer.Allocating = .init(alloc);
        const prepared = (try prepare(alloc, "run", file, &output.writer)) orelse {
            failures += 1;
            continue;
        };

        const out_name = try std.fmt.allocPrint(alloc, "tests/run/{s}.out", .{file.name[0 .. file.name.len - ".juck".len]});
        const expected = std.Io.Dir.cwd().readFileAlloc(io, out_name, alloc, .limited(1 << 24)) catch {
            std.debug.print("FAIL run/{s}: missing {s}\n", .{ file.name, out_name });
            failures += 1;
            continue;
        };

        var diag: reader.Diagnostic = undefined;
        interpreter.run(file.src, prepared.program, alloc, &output.writer, &diag, .{
            .gensyms = &prepared.expander.gensyms,
            .macros = prepared.expander.host(),
        }) catch {
            std.debug.print("FAIL run/{s}: runtime error {d}:{d}: {s}\n", .{ file.name, diag.line, diag.column, diag.message });
            failures += 1;
            continue;
        };
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
        const prepared = (try prepare(alloc, "runtime_errors", file, &output.writer)) orelse {
            failures += 1;
            continue;
        };

        var diag: reader.Diagnostic = undefined;
        // A low limit keeps the deep-recursion test fast.
        if (interpreter.run(file.src, prepared.program, alloc, &output.writer, &diag, .{
            .max_call_depth = 1000,
            .gensyms = &prepared.expander.gensyms,
            .macros = prepared.expander.host(),
        })) |_| {
            std.debug.print("FAIL runtime_errors/{s}: ran without errors\n", .{file.name});
            failures += 1;
            continue;
        } else |err| if (err != error.RuntimeError) return err;

        if (harness.expectedError(file.src)) |want| {
            if (want.line != diag.line or want.column != diag.column) {
                std.debug.print("FAIL runtime_errors/{s}: expected error at {d}:{d}, got {d}:{d} ({s})\n", .{
                    file.name, want.line, want.column, diag.line, diag.column, diag.message,
                });
                failures += 1;
            }
        }
    }
    try std.testing.expectEqual(0, failures);
}
