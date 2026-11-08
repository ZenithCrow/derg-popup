const std = @import("std");

const release_win_sdls_include_path = "win_deps/include";
const release_win_sdls_lib_path = "win_deps";
const release_linux_sdls_include_path = "/usr/include";
const release_linux_sdls_lib_path = "/usr/lib";
const max_num_targets = 10;

const PopupVariant = enum(u32) {
    clock = 0,
    battery = 1,
};

const PopupVariantExe = struct {
    name: []const u8,
    sub_path: []const u8,
};
const exes = &[_]PopupVariantExe{
    .{ .name = "derg-clock-popup", .sub_path = "src/main_clock.zig" },
    .{ .name = "derg-battery-popup", .sub_path = "src/main_battery.zig" },
};
const common_mame = "derg-popup";

pub fn build(b: *std.Build) !void {
    var release_targets: [max_num_targets]std.Build.ResolvedTarget = undefined;
    var targ_idx: usize = 0;

    const release_all = b.option(bool, "release-all", "Build for all supported targets in release mode") orelse false;
    var release_windows = b.option(bool, "release-windows", "Build for windows") orelse false;
    var release_linux = b.option(bool, "release-linux", "Build for linux") orelse false;

    if (release_all) {
        release_windows = true;
        release_linux = true;
    }

    const release = release_windows or release_linux;

    if (release) {
        if (release_linux) {
            release_targets[targ_idx] = b.resolveTargetQuery(.{ .os_tag = .linux, .cpu_arch = .x86_64 });
            targ_idx += 1;
        }

        if (release_windows) {
            release_targets[targ_idx] = b.resolveTargetQuery(.{ .os_tag = .windows, .cpu_arch = .x86_64 });
            targ_idx += 1;
        }
    }

    const popup_variant = b.option(PopupVariant, "popup-variant", "Select a popup variant to build. If not specified, all of them will be built.");
    const variants: []const PopupVariantExe = if (popup_variant) |v| &.{exes[@backingInt(v)]} else exes;

    var sdls_include_path = b.option([]const u8, "sdls_include_path", "Path to directory containing SDL3, SDL3_ttf and SDL3_image include directories");
    var sdls_lib_path = b.option([]const u8, "sdls_lib_path", "Path to directory containing SDL3, SDL3_ttf and SDL3_image libraries");

    const targets = if (release) release_targets[0..targ_idx] else &[_]std.Build.ResolvedTarget{b.standardTargetOptions(.{})};
    const optimize: std.lang.Optimize = if (release) .safe else b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run tests");

    for (targets) |target| {
        var target_path: []const u8 = if (target.result.os.tag == .windows) common_mame else "";

        const target_triple = try target.query.zigTriple(b.allocator);
        const name_target_triple = try std.mem.join(b.allocator, "-", &.{ common_mame, target_triple });

        switch (target.result.os.tag) {
            .linux => {
                sdls_include_path = release_linux_sdls_include_path;
                sdls_lib_path = release_linux_sdls_lib_path;
            },
            .windows => {
                sdls_include_path = release_win_sdls_include_path;
                sdls_lib_path = b.pathJoin(&.{ release_win_sdls_lib_path, @tagName(target.result.cpu.arch) });
            },
            else => {},
        }

        if (release) {
            target_path = b.pathJoin(&.{ name_target_triple, target_path });
        }

        const assets_dir = b.pathJoin(&.{ target_path, switch (target.result.os.tag) {
            .linux => b.pathJoin(&.{ "share", common_mame }),
            else => "assets",
        } });

        // right now, translate-c fails to receive include paths from the target module, failing to find the headers, so I translate-c'd them manually
        //
        // const translate_c = b.dependency("translate_c", .{});
        //
        // const Translator = @import("translate_c").Translator;
        // const translator: Translator = .init(translate_c, .{
        //     .c_source_file = b.path("src/c.h"),
        //     .target = target,
        //     .optimize = optimize,
        // });

        const c_mod = b.createModule(.{
            .root_source_file = b.path(try std.mem.join(b.allocator, "", &.{ "src/c-x86_64-", @tagName(target.result.os.tag), ".zig" })),
            // .root_source_file = b.path("src/c-x86_64-linux.zig"),
            .target = target,
            .optimize = optimize,
        });

        var install_exes_buf: [exes.len]*std.Build.Step.InstallArtifact = undefined;
        const install_exes = install_exes_buf[0..variants.len];
        for (variants, 0..) |variant, i| {
            const exe_mod = b.createModule(.{
                .root_source_file = b.path(variant.sub_path),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{
                        .name = "c",
                        //.module = translator.mod,
                        .module = c_mod,
                    },
                },
            });

            const exe_relative_assets_dir = switch (target.result.os.tag) {
                .linux => b.pathJoin(&.{ "..", assets_dir }),
                else => "assets",
            };

            const build_options = b.addOptions();
            build_options.addOption([]const u8, "assets_path", exe_relative_assets_dir);
            exe_mod.addOptions("build_options", build_options);

            if (sdls_include_path) |inc_path| {
                exe_mod.addIncludePath(.{ .cwd_relative = inc_path });
            }

            if (sdls_lib_path) |lib_path| {
                exe_mod.addLibraryPath(.{ .cwd_relative = lib_path });
                exe_mod.addRPath(.{ .cwd_relative = lib_path });
            }

            exe_mod.linkSystemLibrary("SDL3", .{});
            exe_mod.linkSystemLibrary("SDL3_ttf", .{});
            exe_mod.linkSystemLibrary("SDL3_image", .{});

            const exe = b.addExecutable(.{
                .name = variant.name,
                .root_module = exe_mod,
            });

            if (target.result.os.tag == .windows) {
                // to get rid of the ugly terminal window when opening the exe on Windows
                exe.subsystem = .windows;
            }

            const target_bin_dir = if (target.result.os.tag == .windows) target_path else b.pathJoin(&.{ target_path, "bin" });

            const install_exe = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = target_bin_dir } } });
            b.getInstallStep().dependOn(&install_exe.step);
            install_exes[i] = install_exe;

            // const exe_check = b.addExecutable(.{
            //     .name = "exe_check",
            //     .root_module = exe_mod,
            // });
            //
            // const check = b.step("check", "Check if the code compiles");
            // check.dependOn(&exe_check.step);

            // expose run step if only one variant was speficied to avoid clutter
            if (variants.len == 1) {
                const run_step = b.step("run", "Run the app");

                const run_cmd = b.addRunArtifact(exe);
                run_step.dependOn(&run_cmd.step);

                run_cmd.step.dependOn(b.getInstallStep());

                run_cmd.addPassthruArgs();
            }

            const exe_tests = b.addTest(.{
                .root_module = exe.root_module,
            });

            const run_exe_tests = b.addRunArtifact(exe_tests);

            test_step.dependOn(&run_exe_tests.step);
        }

        if (target.result.os.tag == .windows) {
            const sdl_dll = b.addInstallFile(b.path("win_deps/x86_64/SDL3.dll"), b.pathJoin(&.{ target_path, "SDL3.dll" }));
            b.getInstallStep().dependOn(&sdl_dll.step);
            const sdl_ttf_dll = b.addInstallFile(b.path("win_deps/x86_64/SDL3_ttf.dll"), b.pathJoin(&.{ target_path, "SDL3_ttf.dll" }));
            b.getInstallStep().dependOn(&sdl_ttf_dll.step);
            const sdl_image_dll = b.addInstallFile(b.path("win_deps/x86_64/SDL3_image.dll"), b.pathJoin(&.{ target_path, "SDL3_image.dll" }));
            b.getInstallStep().dependOn(&sdl_image_dll.step);
        }

        const assets_install_dir = b.addInstallDirectory(.{ .source_dir = b.path("assets/install"), .install_subdir = ".", .install_dir = .{ .custom = assets_dir } });
        b.getInstallStep().dependOn(&assets_install_dir.step);

        const install_prefix: std.Build.LazyPath = .{ .relative = .{ .base = .install_prefix } };

        if (release and target.result.os.tag == .windows) {
            const zip_tool = b.addSystemCommand(&.{"zip"});
            zip_tool.addArgs(&.{ "-r", "-", name_target_triple });
            zip_tool.setCwd(install_prefix);

            _ = zip_tool.captureStdErr(.{});
            const zip_stdout = zip_tool.captureStdOut(.{});
            const zip_path = try std.mem.join(b.allocator, "", &.{ name_target_triple, ".zip" });
            const zip_file = b.addInstallFile(zip_stdout, zip_path);
            b.getInstallStep().dependOn(&zip_file.step);

            for (install_exes) |ie| {
                zip_tool.step.dependOn(&ie.step);
            }
            b.getInstallStep().dependOn(&zip_tool.step);
        }
    }
}
