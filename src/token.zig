const std = @import("std");

pub const Tag = union(enum) {
    string: []const u8,
    int: []const u8,
    float: []const u8,
    bool: bool,
    null,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    comma,
    colon,
};

pub const Token = struct {
    tag: Tag,
    pos: usize,

    pub fn new(tag: Tag, pos: usize) Token {
        return .{ .tag = tag, .pos = pos };
    }

    pub fn format(self: Token, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.tag) {
            .string => |s| try writer.print("string(\"{s}\")", .{s}),
            .int => |s| try writer.print("int({s})", .{s}),
            .float => |s| try writer.print("float({s})", .{s}),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            else => try writer.writeAll(@tagName(self.tag)),
        }
    }
};
