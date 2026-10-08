const std = @import("std");
const reader = @import("reader");
const ast = @import("ast");
const analyzer = @import("analyzer");
const checker = @import("checker");
const interpreter = @import("interpreter");
const macros = @import("macros");
const stdlib = @import("stdlib");
const unparse = @import("unparse");
const Builtin = @import("builtins").Builtin;

const Allocator = std.mem.Allocator;
const Value = reader.Value;

pub const Module = struct {
    /// std/logic for the standard library, otherwise the file's path
    /// without .juck.
    path: []const u8,
    /// What its globals internal names start with: "" for the root module,
    /// the path and a . for every other module.
    prefix: []const u8,
    /// The modules it imports, by the name it imports them as.
    imports: std.StringHashMapUnmanaged(*Module) = .empty,
    /// Its globals, by the name they were defined with, and whether they
    /// are pub.
    definitions: std.StringHashMapUnmanaged(bool) = .empty,
    program: ast.Program = .{ .items = &.{} },
};

/// Why loading a module failed; Program.diag says more.
pub const LoadError = error{ SyntaxError, ImportFailed, AnalysisFailed, OutOfMemory };

pub const Program = struct {
    alloc: Allocator,
    io: std.Io,
    sources: reader.Sources = .{},
    expander: macros.Expander,
    checker: checker.Session,
    interpreter: interpreter.Session,
    /// Every module loaded so far, by path.
    modules: std.StringHashMapUnmanaged(*Module) = .empty,
    /// Every module after the modules it imports.
    order: std.ArrayList(*Module) = .empty,
    /// The modules being loaded right now, to detect import cycles.
    loading: std.ArrayList(*Module) = .empty,
    root: ?*Module = null,
    /// The last error, set when a function here fails.
    diag: reader.Diagnostic = .{ .line = 0, .column = 0, .message = "" },

    pub fn create(alloc: Allocator, io: std.Io, out: *std.Io.Writer) !*Program {
        const self = try alloc.create(Program);
        self.* = .{
            .alloc = alloc,
            .io = io,
            .expander = .init(alloc, out),
            .checker = .{ .sources = undefined, .alloc = alloc, .diag = null },
            .interpreter = .{ .alloc = alloc, .out = out },
        };
        self.checker.sources = &self.sources;
        self.interpreter.sources = &self.sources;
        self.interpreter.options.gensyms = &self.expander.gensyms;
        self.interpreter.options.macros = self.expander.host();
        self.interpreter.options.scope = self.scope();
        self.checker.scope = self.scope();
        // eval inside a macro body resolves names the same way.
        self.expander.interpreter.options.scope = self.scope();
        return self;
    }

    /// The analyzer options for this program: its macros, generated names and modules.
    pub fn options(self: *Program) analyzer.Options {
        var o = self.expander.options();
        o.scope = self.scope();
        return o;
    }

    // loading

    /// Loads src as the root module, named file_name in errors, along
    /// with everything it imports. On failure, diag says why: the error
    /// is SyntaxError, ImportFailed or AnalysisFailed.
    pub fn load_root(self: *Program, file_name: []const u8, src: []const u8) LoadError!*Module {
        const m = try self.new_module(without_extension(file_name), "");
        self.root = m;
        try self.load(m, file_name, src);
        return m;
    }

    /// A REPL with no file starts with an empty root module.
    pub fn empty_root(self: *Program) !*Module {
        const m = try self.new_module("repl", "");
        self.root = m;
        return m;
    }

    /// Adds a REPL input as a source of the root module; returns the
    /// offset its positions start at.
    pub fn add_input(self: *Program, name: []const u8, text: []const u8) !u32 {
        return self.sources.add(self.alloc, name, text, self.root.?);
    }

    /// For a REPL input that is an import: loads the module into the root,
    /// then checks and runs the modules this import loaded. (A program from
    /// a file does those two steps for all modules at once, in check and
    /// run) If anything fails, the import is undone, so it can be tried
    /// again
    pub fn import_into_root(self: *Program, form: Value) !void {
        if (!is_import(form)) return;
        const root = self.root.?;
        const items = form.data.array;
        const alias: ?[]const u8 = if (items.len == 3 and items[1].data == .string) items[1].data.string else null;
        // If the name is already imported, the import fails with "already
        // imported", and the earlier import must stay.
        const had_alias = if (alias) |a| root.imports.contains(a) else true;
        const first_new = self.order.items.len;

        errdefer {
            if (!had_alias) _ = root.imports.remove(alias.?);
            self.forget_modules_since(first_new);
        }

        try self.import(root, form);
        const loaded = self.order.items[first_new..];
        for (loaded) |m| try self.checker.check_program(&self.sources, m.program, &self.diag);
        for (loaded) |m| try self.interpreter.run_program(&self.sources, m.program, &self.diag);
    }

    /// Forgets every module loaded after the first first_new in order,
    /// including ones whose loading failed before they got there. Their
    /// definitions may stay in the checker and interpreter, but without
    /// the module nothing can refer to them, and loading the module again
    /// redefines them.
    fn forget_modules_since(self: *Program, first_new: usize) void {
        self.order.shrinkRetainingCapacity(first_new);
        // The modules that existed before are the root and those in `order`.
        // Removing invalidates the iterator, so start over after each one.
        outer: while (true) {
            var it = self.modules.iterator();
            while (it.next()) |e| {
                const m = e.value_ptr.*;
                if (m == self.root.? or std.mem.indexOfScalar(*Module, self.order.items, m) != null) continue;
                forget_globals(&self.checker.globals, m.prefix);
                forget_globals(&self.interpreter.globals, m.prefix);
                _ = self.modules.remove(e.key_ptr.*);
                continue :outer;
            }
            break;
        }
    }

    fn forget_globals(map: anytype, prefix: []const u8) void {
        outer: while (true) {
            var it = map.iterator();
            while (it.next()) |e| {
                const name = e.key_ptr.*;
                if (!std.mem.startsWith(u8, name, prefix)) continue;
                if (std.mem.indexOfScalar(u8, name[prefix.len..], '.') != null) continue;
                _ = map.remove(name);
                continue :outer;
            }
            break;
        }
    }

    fn new_module(self: *Program, path: []const u8, prefix: []const u8) !*Module {
        const m = try self.alloc.create(Module);
        m.* = .{ .path = path, .prefix = prefix };
        try self.modules.put(self.alloc, path, m);
        return m;
    }

    fn load(self: *Program, m: *Module, file_name: []const u8, src: []const u8) LoadError!void {
        try self.loading.append(self.alloc, m);
        defer _ = self.loading.pop();

        const offset = try self.sources.add(self.alloc, file_name, src, m);
        const value = reader.read_at(src, offset, self.alloc, &self.diag) catch |err| switch (err) {
            error.InvalidInput => {
                self.diag.file = file_name;
                return error.SyntaxError;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.diag = .{ .line = 1, .column = 1, .message = "the parser failed", .file = file_name };
                return error.SyntaxError;
            },
        };

        // Imports first, wherever they are written: the module's macros
        // may come from them.
        if (value.data == .array) {
            for (value.data.array) |form| {
                if (is_import(form)) try self.import(m, form);
            }
        }

        m.program = try analyzer.analyze(&self.sources, value, self.alloc, &self.diag, self.options());
        for (m.program.items) |item| {
            const name, const is_pub = switch (item) {
                .def => |d| .{ d.name, d.is_pub },
                .@"fn" => |f| .{ f.name, f.is_pub },
                .macro => |mac| .{ mac.name, mac.is_pub },
                .import, .expr => continue,
            };
            if (std.mem.startsWith(u8, name, m.prefix))
                try m.definitions.put(self.alloc, name[m.prefix.len..], is_pub);
        }
        try self.order.append(self.alloc, m);
    }

    /// ["import", name, path]: loads the module, if it isn't loaded yet,
    /// and makes it available in importer as name.
    fn import(self: *Program, importer: *Module, form: Value) LoadError!void {
        const items = form.data.array;
        // A malformed import is reported by the analyzer.
        if (items.len != 3 or items[1].data != .string or items[2].data != .string) return;
        const alias = items[1].data.string;
        const written = items[2].data.string;

        if (importer.imports.contains(alias))
            return self.fail(form.pos, "\"{s}\" is already imported", .{alias});

        const path = if (std.mem.startsWith(u8, written, "std/"))
            written
        else
            try std.fs.path.resolve(self.alloc, &.{ std.fs.path.dirname(importer.path) orelse ".", written });

        for (self.loading.items, 0..) |loading, i| {
            if (!std.mem.eql(u8, loading.path, path)) continue;
            var chain: std.ArrayList(u8) = .empty;
            for (self.loading.items[i..]) |l| {
                try chain.appendSlice(self.alloc, l.path);
                try chain.appendSlice(self.alloc, " -> ");
            }
            try chain.appendSlice(self.alloc, path);
            return self.fail(form.pos, "import cycle: {s}", .{chain.items});
        }

        const target = self.modules.get(path) orelse blk: {
            const file_name = try std.fmt.allocPrint(self.alloc, "{s}.juck", .{path});
            const src = if (std.mem.startsWith(u8, path, "std/"))
                stdlib.get(path) orelse return self.fail(form.pos, "there is no standard library module \"{s}\"", .{path})
            else
                std.Io.Dir.cwd().readFileAlloc(self.io, file_name, self.alloc, .limited(16 * 1024 * 1024)) catch |err|
                    return self.fail(form.pos, "can't read \"{s}\": {t}", .{ file_name, err });
            const t = try self.new_module(path, try std.fmt.allocPrint(self.alloc, "{s}.", .{path}));
            try self.load(t, file_name, src);
            break :blk t;
        };
        try importer.imports.put(self.alloc, alias, target);
    }

    fn fail(self: *Program, pos: u32, comptime fmt: []const u8, args: anytype) error{ ImportFailed, OutOfMemory } {
        self.diag = self.sources.diagnostic(pos, try std.fmt.allocPrint(self.alloc, fmt, args));
        return error.ImportFailed;
    }

    // checking and running

    /// Checks every module, dependencies first. On failure (TypeError),
    /// diag says why.
    pub fn check(self: *Program) !void {
        for (self.order.items) |m| try self.checker.check_program(&self.sources, m.program, &self.diag);
    }

    /// Runs every module, dependencies first: each module's top-level forms
    /// run once. On failure (RuntimeError), diag says why.
    pub fn run(self: *Program) !void {
        for (self.order.items) |m| try self.interpreter.run_program(&self.sources, m.program, &self.diag);
    }

    // names
    fn scope(self: *Program) analyzer.Scope {
        return .{ .ctx = self, .vtable = &scope_vtable };
    }

    const scope_vtable: analyzer.Scope.VTable = .{ .resolve = resolve, .define = define };

    /// The module whose source pos is in.
    fn module_at(self: *Program, pos: u32) *Module {
        if (self.sources.file_of(pos)) |f| {
            if (f.owner) |owner| return @ptrCast(@alignCast(owner));
        }
        return self.root.?;
    }

    fn resolve(ctx: *anyopaque, pos: u32, name: []const u8, message: *[]const u8) analyzer.Scope.Failure![]const u8 {
        const self: *Program = @ptrCast(@alignCast(ctx));
        const m = self.module_at(pos);

        if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
            const alias = name[0..dot];
            const member = name[dot + 1 ..];
            const target = m.imports.get(alias) orelse {
                message.* = try std.fmt.allocPrint(self.alloc, "there is no import named \"{s}\"", .{alias});
                return error.ScopeFailed;
            };
            const is_pub = target.definitions.get(member) orelse {
                message.* = try std.fmt.allocPrint(self.alloc, "module \"{s}\" has no \"{s}\"", .{ target.path, member });
                return error.ScopeFailed;
            };
            if (!is_pub) {
                message.* = try std.fmt.allocPrint(self.alloc, "\"{s}\" is not pub in module \"{s}\"", .{ member, target.path });
                return error.ScopeFailed;
            }
            return std.fmt.allocPrint(self.alloc, "{s}{s}", .{ target.prefix, member });
        }

        if (m.imports.contains(name)) {
            message.* = try std.fmt.allocPrint(self.alloc, "\"{s}\" is a module; use \"{s}.name\" for something in it", .{ name, name });
            return error.ScopeFailed;
        }
        if (Builtin.lookup(name) != null) return name;

        // A name written in another module than the one being analyzed came
        // from one of that module's macros. The expansion becomes part of
        // this module (and of its --expand output), so it can only use
        // what the macro's module makes pub, like any other code here.
        if (m != self.current()) {
            if (m.definitions.get(name)) |is_pub| if (!is_pub) {
                message.* = try std.fmt.allocPrint(self.alloc, "a macro from module \"{s}\" uses \"{s}\", which is not pub there", .{ m.path, name });
                return error.ScopeFailed;
            };
        }
        if (m.prefix.len == 0) return name;
        return std.fmt.allocPrint(self.alloc, "{s}{s}", .{ m.prefix, name });
    }

    /// The module being analyzed: the innermost one being loaded, or the
    /// root (the REPL's inputs belong to it).
    fn current(self: *Program) *Module {
        const loading = self.loading.items;
        return if (loading.len > 0) loading[loading.len - 1] else self.root.?;
    }

    fn define(ctx: *anyopaque, pos: u32, name: []const u8) Allocator.Error![]const u8 {
        const self: *Program = @ptrCast(@alignCast(ctx));
        const m = self.module_at(pos);
        if (m.prefix.len == 0) return name;
        return std.fmt.allocPrint(self.alloc, "{s}{s}", .{ m.prefix, name });
    }

    /// How the root module refers to the modules it imports, for printing
    /// internal names the way they would be written: `str.concat` for
    /// std/str.concat
    pub fn root_aliases(self: *Program) ![]const unparse.Alias {
        var out: std.ArrayList(unparse.Alias) = .empty;
        var it = self.root.?.imports.iterator();
        while (it.next()) |e| try out.append(self.alloc, .{ .prefix = e.value_ptr.*.prefix, .alias = e.key_ptr.* });
        return out.toOwnedSlice(self.alloc);
    }
};

/// Whether form is ["import", ...]
pub fn is_import(form: Value) bool {
    if (form.data != .array or form.data.array.len == 0) return false;
    const head = form.data.array[0];
    return head.data == .string and std.mem.eql(u8, head.data.string, "import");
}

fn without_extension(file_name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, file_name, ".juck")) file_name[0 .. file_name.len - ".juck".len] else file_name;
}
