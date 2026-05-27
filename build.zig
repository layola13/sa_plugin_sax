const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sa_repo_root = b.option([]const u8, "sa-repo-root", "SA repository root used to resolve sa_std imports.") orelse "/home/vscode/projects/sci";
    const sa_bin = b.option([]const u8, "sa-bin", "Path to the SA host binary used for SAX integration tests.") orelse b.pathJoin(&.{ sa_repo_root, "zig-out/bin/sa" });
    const llvm_include_dir = b.option([]const u8, "llvm-include-dir", "LLVM C API include directory.") orelse "/usr/lib/llvm-14/include";
    const llvm_lib_dir = b.option([]const u8, "llvm-lib-dir", "LLVM library directory.") orelse "/usr/lib/llvm-14/lib";
    const llvm_lib_name = b.option([]const u8, "llvm-lib-name", "LLVM system library name.") orelse "LLVM-14";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "repo_root", sa_repo_root);

    const plugin_api = b.createModule(.{
        .root_source_file = b.path("src/plugin_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addImport("plugin_api", plugin_api);
    root_module.addOptions("build_options", build_options);
    addLlvmcShimToModule(b, root_module);
    linkLLVMToModule(root_module, llvm_include_dir, llvm_lib_dir, llvm_lib_name);
    const lib = b.addLibrary(.{
        .name = "sax",
        .root_module = root_module,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run plugin tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(b.getInstallStep());

    const sa_unit = b.addSystemCommand(&.{ sa_bin, "test", "tests/sax_init_contract.sa" });
    sa_unit.addFileInput(b.path("tests/sax_init_contract.sa"));
    test_step.dependOn(&sa_unit.step);

    const sa_ptr_state_unit = b.addSystemCommand(&.{ sa_bin, "test", "tests/sax_ptr_state_contract.sa" });
    sa_ptr_state_unit.addFileInput(b.path("tests/sax_ptr_state_contract.sa"));
    test_step.dependOn(&sa_ptr_state_unit.step);

    const sa_expr_unit = b.addSystemCommand(&.{ sa_bin, "test", "tests/sax_expr_interpolation_contract.sa" });
    sa_expr_unit.addFileInput(b.path("tests/sax_expr_interpolation_contract.sa"));
    test_step.dependOn(&sa_expr_unit.step);

    const sa_event_unit = b.addSystemCommand(&.{ sa_bin, "test", "tests/sax_event_binding_contract.sa" });
    sa_event_unit.addFileInput(b.path("tests/sax_event_binding_contract.sa"));
    test_step.dependOn(&sa_event_unit.step);

    const sa_typed_unit = b.addSystemCommand(&.{ sa_bin, "test", "tests/sax_typed_state_contract.sa" });
    sa_typed_unit.addFileInput(b.path("tests/sax_typed_state_contract.sa"));
    test_step.dependOn(&sa_typed_unit.step);

    const installed_lib = b.getInstallPath(.lib, "libsax.so");
    const plugin_lib_input = lib.getEmittedBin();
    const counter_demo_input = b.path("demos/counter.sax");
    const todo_demo_input = b.path("demos/todolist.sax");
    const dashboard_demo_input = b.path("demos/reactive_dashboard.sax");
    const buffer_demo_input = b.path("demos/buffer_state.sax");
    const attrs_demo_input = b.path("demos/allowed_attrs.sax");
    const expr_demo_input = b.path("demos/expression_interpolation.sax");
    const typed_demo_input = b.path("demos/typed_state_interpolation.sax");

    const counter_check = b.addSystemCommand(&.{ sa_bin, "sax", "check", "demos/counter.sax" });
    counter_check.setEnvironmentVariable("SA_PLUGINS_PATH", installed_lib);
    counter_check.addFileInput(plugin_lib_input);
    counter_check.addFileInput(counter_demo_input);
    counter_check.step.dependOn(b.getInstallStep());
    test_step.dependOn(&counter_check.step);

    const counter_build = b.addSystemCommand(&.{ sa_bin, "sax", "build", "demos/counter.sax", "--out-dir" });
    const counter_output = counter_build.addOutputDirectoryArg("sax-counter");
    counter_build.setEnvironmentVariable("SA_PLUGINS_PATH", installed_lib);
    counter_build.addFileInput(plugin_lib_input);
    counter_build.addFileInput(counter_demo_input);
    counter_build.step.dependOn(b.getInstallStep());
    test_step.dependOn(&counter_build.step);

    const demo_check = b.addSystemCommand(&.{ sa_bin, "sax", "check", "demos/reactive_dashboard.sax" });
    demo_check.setEnvironmentVariable("SA_PLUGINS_PATH", installed_lib);
    demo_check.addFileInput(plugin_lib_input);
    demo_check.addFileInput(dashboard_demo_input);
    demo_check.step.dependOn(b.getInstallStep());
    test_step.dependOn(&demo_check.step);

    const demo_build = b.addSystemCommand(&.{ sa_bin, "sax", "build", "demos/reactive_dashboard.sax", "--out-dir" });
    const demo_output = demo_build.addOutputDirectoryArg("sax-reactive-dashboard");
    demo_build.setEnvironmentVariable("SA_PLUGINS_PATH", installed_lib);
    demo_build.addFileInput(plugin_lib_input);
    demo_build.addFileInput(dashboard_demo_input);
    demo_build.step.dependOn(b.getInstallStep());
    test_step.dependOn(&demo_build.step);

    const wasm_verify_module = b.createModule(.{
        .root_source_file = b.path("tools/verify_sax_demo_wasm.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const wasm_verify = b.addExecutable(.{
        .name = "verify-sax-demo-wasm",
        .root_module = wasm_verify_module,
    });

    const run_counter_wasm_verify = b.addRunArtifact(wasm_verify);
    run_counter_wasm_verify.addDirectoryArg(counter_output);
    run_counter_wasm_verify.addArgs(&.{
        "sax_counter_init",
        "sax_counter_render",
        "sax_counter_destroy",
        "sax_counter_inc",
        "sax_counter_dec",
        "sax_counter_reset",
    });
    test_step.dependOn(&run_counter_wasm_verify.step);

    const run_counter_runtime_verify = b.addSystemCommand(&.{ "node", "tools/verify_sax_runtime.mjs" });
    run_counter_runtime_verify.addFileInput(b.path("tools/verify_sax_runtime.mjs"));
    run_counter_runtime_verify.addDirectoryArg(counter_output);
    run_counter_runtime_verify.addArg("counter");
    test_step.dependOn(&run_counter_runtime_verify.step);

    const run_counter_security_verify = b.addSystemCommand(&.{ "node", "tools/verify_sax_runtime.mjs" });
    run_counter_security_verify.addFileInput(b.path("tools/verify_sax_runtime.mjs"));
    run_counter_security_verify.addDirectoryArg(counter_output);
    run_counter_security_verify.addArg("security");
    test_step.dependOn(&run_counter_security_verify.step);

    const todo_check = b.addSystemCommand(&.{ sa_bin, "sax", "check", "demos/todolist.sax" });
    todo_check.setEnvironmentVariable("SA_PLUGINS_PATH", installed_lib);
    todo_check.addFileInput(plugin_lib_input);
    todo_check.addFileInput(todo_demo_input);
    todo_check.step.dependOn(b.getInstallStep());
    test_step.dependOn(&todo_check.step);

    const todo_build = b.addSystemCommand(&.{ sa_bin, "sax", "build", "demos/todolist.sax", "--out-dir" });
    const todo_output = todo_build.addOutputDirectoryArg("sax-todolist");
    todo_build.setEnvironmentVariable("SA_PLUGINS_PATH", installed_lib);
    todo_build.addFileInput(plugin_lib_input);
    todo_build.addFileInput(todo_demo_input);
    todo_build.step.dependOn(b.getInstallStep());
    test_step.dependOn(&todo_build.step);

    const run_todo_wasm_verify = b.addRunArtifact(wasm_verify);
    run_todo_wasm_verify.addDirectoryArg(todo_output);
    run_todo_wasm_verify.addArgs(&.{
        "sax_todolist_init",
        "sax_todolist_render",
        "sax_todolist_destroy",
        "sax_todolist_add",
        "sax_todolist_removeLast",
    });
    test_step.dependOn(&run_todo_wasm_verify.step);

    const run_todo_runtime_verify = b.addSystemCommand(&.{ "node", "tools/verify_sax_runtime.mjs" });
    run_todo_runtime_verify.addFileInput(b.path("tools/verify_sax_runtime.mjs"));
    run_todo_runtime_verify.addDirectoryArg(todo_output);
    run_todo_runtime_verify.addArg("todo");
    test_step.dependOn(&run_todo_runtime_verify.step);

    const run_wasm_verify = b.addRunArtifact(wasm_verify);
    run_wasm_verify.addDirectoryArg(demo_output);
    run_wasm_verify.addArgs(&.{
        "sax_dashboard_init",
        "sax_dashboard_render",
        "sax_dashboard_destroy",
        "sax_dashboard_recordVisit",
        "sax_dashboard_ackAlert",
        "sax_dashboard_improveLatency",
    });
    test_step.dependOn(&run_wasm_verify.step);

    const run_dashboard_runtime_verify = b.addSystemCommand(&.{ "node", "tools/verify_sax_runtime.mjs" });
    run_dashboard_runtime_verify.addFileInput(b.path("tools/verify_sax_runtime.mjs"));
    run_dashboard_runtime_verify.addDirectoryArg(demo_output);
    run_dashboard_runtime_verify.addArg("dashboard");
    test_step.dependOn(&run_dashboard_runtime_verify.step);

    const buffer_check = b.addSystemCommand(&.{ sa_bin, "sax", "check", "demos/buffer_state.sax" });
    buffer_check.setEnvironmentVariable("SA_PLUGINS_PATH", installed_lib);
    buffer_check.addFileInput(plugin_lib_input);
    buffer_check.addFileInput(buffer_demo_input);
    buffer_check.step.dependOn(b.getInstallStep());
    test_step.dependOn(&buffer_check.step);

    const buffer_build = b.addSystemCommand(&.{ sa_bin, "sax", "build", "demos/buffer_state.sax", "--out-dir" });
    const buffer_output = buffer_build.addOutputDirectoryArg("sax-buffer-state");
    buffer_build.setEnvironmentVariable("SA_PLUGINS_PATH", installed_lib);
    buffer_build.addFileInput(plugin_lib_input);
    buffer_build.addFileInput(buffer_demo_input);
    buffer_build.step.dependOn(b.getInstallStep());
    test_step.dependOn(&buffer_build.step);

    const run_buffer_wasm_verify = b.addRunArtifact(wasm_verify);
    run_buffer_wasm_verify.addDirectoryArg(buffer_output);
    run_buffer_wasm_verify.addArgs(&.{
        "sax_bufferlab_init",
        "sax_bufferlab_render",
        "sax_bufferlab_destroy",
        "sax_bufferlab_recordWrite",
    });
    test_step.dependOn(&run_buffer_wasm_verify.step);

    const attrs_check = b.addSystemCommand(&.{ sa_bin, "sax", "check", "demos/allowed_attrs.sax" });
    attrs_check.setEnvironmentVariable("SA_PLUGINS_PATH", installed_lib);
    attrs_check.addFileInput(plugin_lib_input);
    attrs_check.addFileInput(attrs_demo_input);
    attrs_check.step.dependOn(b.getInstallStep());
    test_step.dependOn(&attrs_check.step);

    const attrs_build = b.addSystemCommand(&.{ sa_bin, "sax", "build", "demos/allowed_attrs.sax", "--out-dir" });
    const attrs_output = attrs_build.addOutputDirectoryArg("sax-allowed-attrs");
    attrs_build.setEnvironmentVariable("SA_PLUGINS_PATH", installed_lib);
    attrs_build.addFileInput(plugin_lib_input);
    attrs_build.addFileInput(attrs_demo_input);
    attrs_build.step.dependOn(b.getInstallStep());
    test_step.dependOn(&attrs_build.step);

    const run_attrs_wasm_verify = b.addRunArtifact(wasm_verify);
    run_attrs_wasm_verify.addDirectoryArg(attrs_output);
    run_attrs_wasm_verify.addArgs(&.{
        "sax_attrlab_init",
        "sax_attrlab_render",
        "sax_attrlab_destroy",
        "sax_attrlab_bump",
    });
    test_step.dependOn(&run_attrs_wasm_verify.step);

    const expr_check = b.addSystemCommand(&.{ sa_bin, "sax", "check", "demos/expression_interpolation.sax" });
    expr_check.setEnvironmentVariable("SA_PLUGINS_PATH", installed_lib);
    expr_check.addFileInput(plugin_lib_input);
    expr_check.addFileInput(expr_demo_input);
    expr_check.step.dependOn(b.getInstallStep());
    test_step.dependOn(&expr_check.step);

    const expr_build = b.addSystemCommand(&.{ sa_bin, "sax", "build", "demos/expression_interpolation.sax", "--out-dir" });
    const expr_output = expr_build.addOutputDirectoryArg("sax-expression-interpolation");
    expr_build.setEnvironmentVariable("SA_PLUGINS_PATH", installed_lib);
    expr_build.addFileInput(plugin_lib_input);
    expr_build.addFileInput(expr_demo_input);
    expr_build.step.dependOn(b.getInstallStep());
    test_step.dependOn(&expr_build.step);

    const run_expr_wasm_verify = b.addRunArtifact(wasm_verify);
    run_expr_wasm_verify.addDirectoryArg(expr_output);
    run_expr_wasm_verify.addArgs(&.{
        "sax_exprlab_init",
        "sax_exprlab_render",
        "sax_exprlab_destroy",
        "sax_exprlab_bump",
    });
    test_step.dependOn(&run_expr_wasm_verify.step);

    const typed_check = b.addSystemCommand(&.{ sa_bin, "sax", "check", "demos/typed_state_interpolation.sax" });
    typed_check.setEnvironmentVariable("SA_PLUGINS_PATH", installed_lib);
    typed_check.addFileInput(plugin_lib_input);
    typed_check.addFileInput(typed_demo_input);
    typed_check.step.dependOn(b.getInstallStep());
    test_step.dependOn(&typed_check.step);

    const typed_build = b.addSystemCommand(&.{ sa_bin, "sax", "build", "demos/typed_state_interpolation.sax", "--out-dir" });
    const typed_output = typed_build.addOutputDirectoryArg("sax-typed-state-interpolation");
    typed_build.setEnvironmentVariable("SA_PLUGINS_PATH", installed_lib);
    typed_build.addFileInput(plugin_lib_input);
    typed_build.addFileInput(typed_demo_input);
    typed_build.step.dependOn(b.getInstallStep());
    test_step.dependOn(&typed_build.step);

    const run_typed_wasm_verify = b.addRunArtifact(wasm_verify);
    run_typed_wasm_verify.addDirectoryArg(typed_output);
    run_typed_wasm_verify.addArgs(&.{
        "sax_typedlab_init",
        "sax_typedlab_render",
        "sax_typedlab_destroy",
        "sax_typedlab_bump",
    });
    test_step.dependOn(&run_typed_wasm_verify.step);

    const run_typed_runtime_verify = b.addSystemCommand(&.{ "node", "tools/verify_sax_runtime.mjs" });
    run_typed_runtime_verify.addFileInput(b.path("tools/verify_sax_runtime.mjs"));
    run_typed_runtime_verify.addDirectoryArg(typed_output);
    run_typed_runtime_verify.addArg("typed");
    test_step.dependOn(&run_typed_runtime_verify.step);
}

fn addLlvmcShimToModule(b: *std.Build, module: *std.Build.Module) void {
    module.addCSourceFile(.{ .file = b.path("src/emit_llvm_llvmc_shim.c"), .flags = &.{} });
}

fn linkLLVMToModule(module: *std.Build.Module, include_dir: []const u8, lib_dir: []const u8, lib_name: []const u8) void {
    module.addSystemIncludePath(.{ .cwd_relative = include_dir });
    module.addLibraryPath(.{ .cwd_relative = lib_dir });
    module.linkSystemLibrary(lib_name, .{});
}
