const std = @import("std");

// Copies web/dist next to a generated assets.zig that @embedFile's every file.
const gen_script =
    \\set -e; out="$1"; src="$2"; mkdir -p "$out/files"; cp -R "$src/." "$out/files/"
    \\{ printf 'pub const File = struct { path: []const u8, data: []const u8 };\npub const files = [_]File{\n'
    \\  (cd "$out/files" && find . -type f | sed 's|^\./||' | while IFS= read -r f; do
    \\    printf '    .{ .path = "/%s", .data = @embedFile("files/%s") },\n' "$f" "$f"; done)
    \\  printf '};\n'; } > "$out/assets.zig"
;

fn linkSqlite(m: *std.Build.Module) void {
    m.linkSystemLibrary("sqlite3", .{}); // macOS ships it; store.zig declares the C subset itself
    m.link_libc = true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // web build -> assets module
    const npm_ci = b.addSystemCommand(&.{ "npm", "ci" });
    npm_ci.setCwd(b.path("web"));
    npm_ci.has_side_effects = true;
    const npm_build = b.addSystemCommand(&.{ "npm", "run", "build" });
    npm_build.setCwd(b.path("web"));
    npm_build.has_side_effects = true;
    npm_build.step.dependOn(&npm_ci.step);
    const gen = b.addSystemCommand(&.{ "sh", "-c", gen_script, "sh" });
    const gen_dir = gen.addOutputDirectoryArg("assets");
    gen.addDirectoryArg(b.path("web/dist"));
    gen.has_side_effects = true; // dist contents are not tracked as inputs
    gen.step.dependOn(&npm_build.step);
    const assets = b.createModule(.{ .root_source_file = gen_dir.path(b, "assets.zig") });

    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    const exe_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    exe_mod.addImport("assets", assets);
    exe_mod.addImport("nanoui", nanoui);
    linkSqlite(exe_mod);
    const opts = b.addOptions(); // build.zig.zon is the single source of the app version
    opts.addOption([]const u8, "version", @import("build.zig.zon").version);
    exe_mod.addOptions("build_options", opts);
    const exe = b.addExecutable(.{ .name = "nanodraw", .root_module = exe_mod });
    b.installArtifact(exe);

    // tests: stub assets so `zig build test` needs no npm
    const stub = b.addWriteFiles().add("assets.zig", "pub const File = struct { path: []const u8, data: []const u8 };\npub const files = [_]File{};\n");
    const stub_assets = b.createModule(.{ .root_source_file = stub });
    const test_step = b.step("test", "Run unit tests (incl. shared WS fixture)");
    for ([_][]const u8{ "protocol", "store", "view", "core", "net", "log" }) |name| {
        const m = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        m.addImport("assets", stub_assets);
        m.addAnonymousImport("ws_calls", .{ .root_source_file = b.path("mcp/test/ws-calls.jsonl") }); // net.zig fixture test
        linkSqlite(m);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }
}
