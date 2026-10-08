const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("juck", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    const LexerImpl = enum { manual, regex };

    const lexer_impl = b.option(LexerImpl, "lexer", "Lexer implementation to use (default: manual)") orelse .manual;

    const token_mod = b.createModule(.{
        .root_source_file = b.path("src/token.zig"),
        .target = target,
    });

    const options = b.addOptions();
    options.addOption(LexerImpl, "lexer", lexer_impl);

    const ezi_gex = b.dependency("ezi_gex", .{ .target = target, .optimize = optimize });

    const lexer_mod = b.addModule("lexer", .{
        .root_source_file = b.path("src/lexer.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "token", .module = token_mod },
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "ezi_gex", .module = ezi_gex.module("ezi_gex") },
        },
    });

    const manual_lexer_mod = b.createModule(.{
        .root_source_file = b.path("src/manual_lexer.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "token", .module = token_mod },
        },
    });
    lexer_mod.addImport("manual_lexer", manual_lexer_mod);

    const regex_lexer_mod = b.createModule(.{
        .root_source_file = b.path("src/regex_lexer.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "token", .module = token_mod },
            .{ .name = "ezi_gex", .module = ezi_gex.module("ezi_gex") },
        },
    });
    lexer_mod.addImport("regex_lexer", regex_lexer_mod);

    const ts_options = b.addOptions();
    ts_options.addOption(bool, "enable_wasm", false);

    const ts_mod = b.createModule(.{
        .root_source_file = b.path("deps/zig-tree-sitter/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ts_mod.addOptions("build", ts_options);
    ts_mod.addCSourceFile(.{ .file = b.path("deps/tree-sitter/lib/src/lib.c"), .flags = &.{"-std=c11"} });
    ts_mod.addIncludePath(b.path("deps/tree-sitter/lib/include"));
    ts_mod.addIncludePath(b.path("deps/tree-sitter/lib/src"));
    ts_mod.addCMacro("_POSIX_C_SOURCE", "200112L");
    ts_mod.addCMacro("_DEFAULT_SOURCE", "");
    ts_mod.addCMacro("_BSD_SOURCE", "");
    ts_mod.addCMacro("_DARWIN_C_SOURCE", "");

    const ts_gen = b.addSystemCommand(&.{ "tree-sitter", "generate", "--js-runtime", "native" });
    ts_gen.addFileArg(b.path("tree_sitter_juck/grammar.js"));
    ts_gen.addArg("-o");
    const ts_gen_dir = ts_gen.addOutputDirectoryArg("tree_sitter_juck");
    ts_gen.setCwd(b.path("tree_sitter_juck"));

    // Neovim plugin: `zig build nvim` assembles zig-out/nvim/, a plugin
    // directory with the parser, the highlight queries and the Lua files.
    const nvim_step = b.step("nvim", "Build the Neovim plugin into zig-out/nvim");
    const nvim_parser = b.addLibrary(.{
        .name = "juck",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    nvim_parser.root_module.addCSourceFile(.{ .file = ts_gen_dir.path(b, "parser.c") });
    nvim_parser.root_module.addIncludePath(ts_gen_dir);
    nvim_step.dependOn(&b.addInstallFileWithDir(nvim_parser.getEmittedBin(), .{ .custom = "nvim/parser" }, "juck.so").step);
    nvim_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("tree_sitter_juck/queries"),
        .install_dir = .prefix,
        .install_subdir = "nvim/queries/juck",
    }).step);
    nvim_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("editors/nvim"),
        .install_dir = .prefix,
        .install_subdir = "nvim",
    }).step);
    const reader_mod = b.createModule(.{
        .root_source_file = b.path("src/ts_reader.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "tree-sitter", .module = ts_mod }},
    });
    reader_mod.addCSourceFile(.{ .file = ts_gen_dir.path(b, "parser.c") });
    reader_mod.addIncludePath(ts_gen_dir);

    const printer_mod = b.createModule(.{
        .root_source_file = b.path("src/printer.zig"),
        .target = target,
        .imports = &.{.{ .name = "reader", .module = reader_mod }},
    });

    const ast_mod = b.createModule(.{
        .root_source_file = b.path("src/ast.zig"),
        .target = target,
        .imports = &.{.{ .name = "reader", .module = reader_mod }},
    });

    const analyzer_mod = b.createModule(.{
        .root_source_file = b.path("src/analyzer.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "reader", .module = reader_mod },
            .{ .name = "ast", .module = ast_mod },
        },
    });

    const harness_mod = b.createModule(.{
        .root_source_file = b.path("tests/harness.zig"),
        .target = target,
    });

    const builtins_mod = b.createModule(.{
        .root_source_file = b.path("src/builtins.zig"),
        .target = target,
    });
    const checker_mod = b.createModule(.{
        .root_source_file = b.path("src/checker.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "reader", .module = reader_mod },
            .{ .name = "ast", .module = ast_mod },
            .{ .name = "analyzer", .module = analyzer_mod },
            .{ .name = "builtins", .module = builtins_mod },
        },
    });

    const interpreter_mod = b.createModule(.{
        .root_source_file = b.path("src/interpreter.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "reader", .module = reader_mod },
            .{ .name = "ast", .module = ast_mod },
            .{ .name = "analyzer", .module = analyzer_mod },
            .{ .name = "printer", .module = printer_mod },
            .{ .name = "builtins", .module = builtins_mod },
            .{ .name = "checker", .module = checker_mod },
        },
    });

    // The standard library, embedded in the binary: std/NAME.juck is the
    // module "std/NAME". Add new modules to this list.
    const std_modules = [_][]const u8{ "logic", "math", "str" };
    const stdlib_files = b.addWriteFiles();
    var stdlib_src: std.ArrayList(u8) = .empty;
    stdlib_src.appendSlice(
        b.allocator,
        "const std = @import(\"std\");\n\n/// The source of a standard library module, by path (\"std/logic\").\npub fn get(path: []const u8) ?[]const u8 {\n",
    ) catch @panic("OOM");
    for (std_modules) |name| {
        const file = b.fmt("{s}.juck", .{name});
        _ = stdlib_files.addCopyFile(b.path(b.fmt("std/{s}", .{file})), file);
        stdlib_src.appendSlice(
            b.allocator,
            b.fmt(
                "    if (std.mem.eql(u8, path, \"std/{s}\")) return @embedFile(\"{s}\");\n",
                .{ name, file },
            ),
        ) catch @panic("OOM");
    }
    stdlib_src.appendSlice(b.allocator, "    return null;\n}\n") catch @panic("OOM");
    const stdlib_mod = b.createModule(.{
        .root_source_file = stdlib_files.add("stdlib.zig", stdlib_src.items),
        .target = target,
    });

    const macros_mod = b.createModule(.{
        .root_source_file = b.path("src/macros.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "reader", .module = reader_mod },
            .{ .name = "ast", .module = ast_mod },
            .{ .name = "analyzer", .module = analyzer_mod },
            .{ .name = "checker", .module = checker_mod },
            .{ .name = "interpreter", .module = interpreter_mod },
        },
    });

    const unparse_mod = b.createModule(.{
        .root_source_file = b.path("src/unparse.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "reader", .module = reader_mod },
            .{ .name = "ast", .module = ast_mod },
            .{ .name = "printer", .module = printer_mod },
        },
    });

    const modules_mod = b.createModule(.{
        .root_source_file = b.path("src/modules.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "reader", .module = reader_mod },
            .{ .name = "ast", .module = ast_mod },
            .{ .name = "analyzer", .module = analyzer_mod },
            .{ .name = "checker", .module = checker_mod },
            .{ .name = "interpreter", .module = interpreter_mod },
            .{ .name = "macros", .module = macros_mod },
            .{ .name = "stdlib", .module = stdlib_mod },
            .{ .name = "unparse", .module = unparse_mod },
            .{ .name = "builtins", .module = builtins_mod },
        },
    });

    const repl_mod = b.createModule(.{
        .root_source_file = b.path("src/repl.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "reader", .module = reader_mod },
            .{ .name = "ast", .module = ast_mod },
            .{ .name = "analyzer", .module = analyzer_mod },
            .{ .name = "checker", .module = checker_mod },
            .{ .name = "interpreter", .module = interpreter_mod },
            .{ .name = "macros", .module = macros_mod },
            .{ .name = "unparse", .module = unparse_mod },
            .{ .name = "printer", .module = printer_mod },
            .{ .name = "modules", .module = modules_mod },
        },
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "juck",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "juck" is the name you will use in your source code to
                // import this module (e.g. `@import("juck")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "juck", .module = mod },
            },
        }),
    });

    exe.root_module.addImport("lexer", lexer_mod);
    exe.root_module.addImport("reader", reader_mod);
    exe.root_module.addImport("printer", printer_mod);
    exe.root_module.addImport("analyzer", analyzer_mod);
    exe.root_module.addImport("checker", checker_mod);
    exe.root_module.addImport("interpreter", interpreter_mod);
    exe.root_module.addImport("repl", repl_mod);
    exe.root_module.addImport("stdlib", stdlib_mod);
    exe.root_module.addImport("macros", macros_mod);
    exe.root_module.addImport("unparse", unparse_mod);
    exe.root_module.addImport("modules", modules_mod);

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    run_cmd.addPassthruArgs();

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const reader_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/reader_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "reader", .module = reader_mod },
                .{ .name = "printer", .module = printer_mod },
                .{ .name = "harness", .module = harness_mod },
            },
        }),
    });
    const run_reader_tests = b.addRunArtifact(reader_tests);
    run_reader_tests.setCwd(b.path("."));

    const ast_tests = b.addTest(.{ .root_module = ast_mod });

    const analyzer_unit_tests = b.addTest(.{ .root_module = analyzer_mod });

    const analyzer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/analyzer_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "reader", .module = reader_mod },
                .{ .name = "analyzer", .module = analyzer_mod },
                .{ .name = "harness", .module = harness_mod },
                .{ .name = "checker", .module = checker_mod },
                .{ .name = "macros", .module = macros_mod },
                .{ .name = "modules", .module = modules_mod },
            },
        }),
    });
    const run_analyzer_tests = b.addRunArtifact(analyzer_tests);
    run_analyzer_tests.setCwd(b.path("."));

    const run_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/run_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "reader", .module = reader_mod },
                .{ .name = "ast", .module = ast_mod },
                .{ .name = "analyzer", .module = analyzer_mod },
                .{ .name = "checker", .module = checker_mod },
                .{ .name = "interpreter", .module = interpreter_mod },
                .{ .name = "modules", .module = modules_mod },
            },
        }),
    });
    const run_run_tests = b.addRunArtifact(run_tests);
    run_run_tests.setCwd(b.path("."));

    const repl_unit_tests = b.addTest(.{ .root_module = repl_mod });

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_reader_tests.step);
    test_step.dependOn(&b.addRunArtifact(ast_tests).step);
    test_step.dependOn(&b.addRunArtifact(analyzer_unit_tests).step);
    test_step.dependOn(&run_analyzer_tests.step);
    test_step.dependOn(&b.addRunArtifact(repl_unit_tests).step);

    b.getInstallStep().dependOn(&run_reader_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
