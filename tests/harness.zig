const std = @import("std");

const io = std.testing.io;

pub const File = struct { name: []const u8, src: []const u8 };

/// Reads every .juck file in dir_path (relative to the project root)
pub fn juck_files(alloc: std.mem.Allocator, dir_path: []const u8) ![]File {
    var files: std.ArrayList(File) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".juck")) continue;
        try files.append(alloc, .{
            .name = try alloc.dupe(u8, entry.name),
            .src = try dir.readFileAlloc(io, entry.name, alloc, .limited(1 << 24)),
        });
    }
    return files.toOwnedSlice(alloc);
}

pub const Position = struct { line: u32, column: u32 };

/// Parses a `// error: LINE:COL` header on the first line, if present
pub fn expected_error(src: []const u8) ?Position {
    const prefix = "// error: ";
    if (!std.mem.startsWith(u8, src, prefix)) return null;
    const line_end = std.mem.indexOfScalar(u8, src, '\n') orelse src.len;
    const spec = std.mem.trim(u8, src[prefix.len..line_end], " \r");
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return null;
    return .{
        .line = std.fmt.parseInt(u32, spec[0..colon], 10) catch return null,
        .column = std.fmt.parseInt(u32, spec[colon + 1 ..], 10) catch return null,
    };
}
