const std = @import("std");
const reader = @import("reader");
const ast = @import("ast");
const analyzer = @import("analyzer");
const checker = @import("checker");
const interpreter = @import("interpreter");

const Allocator = std.mem.Allocator;
const Diagnostic = reader.Diagnostic;
const Failure = analyzer.MacroHost.Failure;

pub const Expander = struct {
    alloc: Allocator,
    /// Every generated name, from macros and from the program.
    gensyms: analyzer.Gensyms = .{},
    checker: checker.Session,
    interpreter: interpreter.Session,
    /// Every macro defined so far, by name.
    macros: std.StringHashMapUnmanaged(*const ast.Macro) = .empty,

    /// out is where print in a macro body writes, while expanding.
    pub fn init(alloc: Allocator, out: *std.Io.Writer) Expander {
        return .{
            .alloc = alloc,
            .checker = .{ .src = "", .alloc = alloc, .diag = null },
            .interpreter = .{ .alloc = alloc, .out = out },
        };
    }

    /// The analyzer options that use this expander. The expander must not
    /// move while they are in use.
    pub fn options(self: *Expander) analyzer.Options {
        self.interpreter.options.gensyms = &self.gensyms;
        self.interpreter.options.macros = self.host();
        return .{ .macros = self.host(), .gensyms = &self.gensyms };
    }

    pub fn host(self: *Expander) analyzer.MacroHost {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: analyzer.MacroHost.VTable = .{
        .is_macro = is_macro,
        .define = define,
        .define_comptime = define_comptime,
        .expand = expand,
    };

    fn is_macro(ctx: *anyopaque, name: []const u8) bool {
        const self: *Expander = @ptrCast(@alignCast(ctx));
        return self.macros.contains(name);
    }

    /// Checks a macro's body like a function from data to data, then
    /// compiles it, as a function named like the macro, in the macro world.
    /// Defining a macro again replaces it; code already expanded keeps the
    /// old expansion.
    fn define(ctx: *anyopaque, src: []const u8, m: *const ast.Macro, diag: *Diagnostic) Failure!void {
        const self: *Expander = @ptrCast(@alignCast(ctx));
        if (self.checker.globals.contains(m.name) and !self.macros.contains(m.name))
            return self.fail(src, m.pos, diag, "\"{s}\" is already a comptime function", .{m.name});
        try self.compile(src, .{ .pos = m.pos, .name = m.name, .doc = m.doc, .lambda = m.lambda }, diag);
        const stored = try self.alloc.create(ast.Macro);
        stored.* = m.*;
        try self.macros.put(self.alloc, m.name, stored);
    }

    /// Compiles a comptime function into the macro world, so macros (and
    /// other comptime functions) can call it.
    fn define_comptime(ctx: *anyopaque, src: []const u8, f: *const ast.Fn, diag: *Diagnostic) Failure!void {
        const self: *Expander = @ptrCast(@alignCast(ctx));
        if (self.macros.contains(f.name))
            return self.fail(src, f.pos, diag, "\"{s}\" is already a macro", .{f.name});
        try self.compile(src, f.*, diag);
    }

    /// Checks and compiles a function in the macro world, replacing any
    /// earlier one with the same name.
    fn compile(self: *Expander, src: []const u8, f: ast.Fn, diag: *Diagnostic) Failure!void {
        const previous = self.checker.globals.get(f.name);
        _ = self.checker.globals.remove(f.name);

        const item = try self.alloc.create(ast.TopLevel);
        item.* = .{ .@"fn" = f };
        _ = self.checker.check_form(src, item.*, diag) catch |err| switch (err) {
            error.TypeError => {
                self.checker.restore(f.name, previous);
                // The most likely mistake: using something that only exists
                // when the program runs.
                if (std.mem.startsWith(u8, diag.message, "unknown name"))
                    diag.message = try std.fmt.allocPrint(self.alloc, "{s}; at compile time, only built-ins, macros and functions marked \"comptime\": true exist", .{diag.message});
                return error.MacroFailed;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        _ = self.interpreter.run_form(src, item, diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MacroFailed, // defining a function can't fail otherwise
        };
    }

    fn fail(self: *Expander, src: []const u8, pos: u32, diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Failure {
        diag.* = analyzer.diagnostic_at(src, pos, try std.fmt.allocPrint(self.alloc, fmt, args));
        return error.MacroFailed;
    }

    /// Runs a macro on a call's arguments.
    fn expand(ctx: *anyopaque, src: []const u8, name: []const u8, pos: u32, args: []const reader.Value, diag: *Diagnostic) Failure!reader.Value {
        const self: *Expander = @ptrCast(@alignCast(ctx));
        const m = self.macros.get(name).?;

        const fixed = m.fixed();
        if (args.len < fixed or (!m.has_rest and args.len > fixed)) {
            const expected = if (m.has_rest)
                try std.fmt.allocPrint(self.alloc, "at least {d}", .{fixed})
            else
                try std.fmt.allocPrint(self.alloc, "{d}", .{fixed});
            const message = try std.fmt.allocPrint(self.alloc, "the macro \"{s}\" takes {s} argument(s), but {d} were given", .{ name, expected, args.len });
            diag.* = analyzer.diagnostic_at(src, pos, message);
            return error.MacroFailed;
        }

        const values = try self.alloc.alloc(interpreter.Value, m.lambda.params.len);
        for (args[0..fixed], values[0..fixed]) |arg, *v| v.* = .{ .data = arg };
        if (m.has_rest) values[fixed] = .{ .data = .{
            .pos = pos,
            .data = .{ .array = try self.alloc.dupe(reader.Value, args[fixed..]) },
        } };

        const f = self.interpreter.globals.get(name).?.func;
        const result = self.interpreter.apply(src, f, values, pos, diag) catch |err| switch (err) {
            error.RuntimeError => {
                diag.message = try std.fmt.allocPrint(self.alloc, "in the expansion of \"{s}\": {s}", .{ name, diag.message });
                return error.MacroFailed;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MacroFailed, // writing to `out` failed
        };
        return result.data;
    }
};
