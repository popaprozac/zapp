const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("probe.h");
});

// Phase 2 vertical slice — reimplements one real Zapp path
// (mirrors `router_handle_window_action`) to grade ergonomics on the patterns
// we actually use: bridge-JSON → route on `m` → window create, a platform-gated
// action, a struct+method, const-correctness threading, and the raw→.m-wrapper
// architecture (no inline ObjC in the orchestration lang).

// (3) A struct + method — the WindowOptions-like value object.
// (4) Const-correctness: `title` is a `[:0]const u8` (immutable, NUL-terminated)
//     owned upstream by the arena and threaded straight into C's `const char*`.
//     Zig keeps the const-ness end to end: no cast wrangling, `.ptr` on a
//     `[:0]const u8` is exactly `[*:0]const u8`, which @cImport mapped the
//     `const char*` param to. No discard-qualifier fights like Zen-C's.
const WindowOptions = struct {
    w: c_int,
    h: c_int,
    title: [:0]const u8,

    // (5) raw→wrapper: the ObjC that sets `win.title` lives in
    // probe_cocoa.m behind the plain C `spike_cocoa_open_window`. This method
    // just forwards the already-NUL-terminated const slice — ZERO inline ObjC
    // in Zig. This is the target architecture (vs Zen-C's `raw { ... }` blocks
    // that inline ObjC into the .zc and emit into every TU).
    fn apply(self: WindowOptions) void {
        c.spike_cocoa_open_window(self.w, self.h, self.title.ptr);
    }
};

// (1)+(3)+(4) window:create handler — parse `a`, build the struct, .apply().
fn handleWindowCreate(a: std.mem.Allocator, args: std.json.Value) !void {
    const obj = args.object;
    const opts = WindowOptions{
        .w = @intCast(obj.get("w").?.integer),
        .h = @intCast(obj.get("h").?.integer),
        // std.json strings are non-NUL-terminated slices; dupeZ gives us a
        // `[:0]const u8` (const-correct, sentinel-terminated) for C.
        .title = try a.dupeZ(u8, obj.get("title").?.string),
    };
    opts.apply();
}

// (2) platform-gated action — COMPILE-TIME OS branch. `builtin.os.tag` is a
// comptime-known value, so the dead branch is elided entirely (the linker never
// sees `spike_print_windows` on macOS). Contrast Zen-C `@cfg`, which emits the
// guarded import/decl into EVERY translation unit and forces a per-platform stub
// — here there is no emit footgun: it's just a normal `if` the compiler folds.
fn handleDockBounce() void {
    if (builtin.os.tag == .macos) {
        c.spike_cocoa_beep();
    } else {
        c.spike_print_windows();
    }
}

// The router — dispatch on the bridge message's `m` field. This is the slice's
// analogue of `router_handle_window_action`.
fn route(a: std.mem.Allocator, msg: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, msg, .{});
    defer parsed.deinit();
    const m = parsed.value.object.get("m").?.string;

    // Tagged dispatch. Zig has no native string-switch, but `std.mem.eql` reads
    // cleanly and is exhaustive-by-intent; the trailing `else` is the default.
    if (std.mem.eql(u8, m, "window:create")) {
        try handleWindowCreate(a, parsed.value.object.get("a").?);
    } else if (std.mem.eql(u8, m, "dock:bounce")) {
        handleDockBounce();
    } else {
        std.debug.print("[slice] unrouted message: {s}\n", .{m});
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // (1) Bridge JSON → route → window create.
    const create_msg =
        \\{"t":4,"m":"window:create","a":{"w":700,"h":500,"title":"slice"}}
    ;
    try route(a, create_msg);

    // (2) platform-gated action.
    const bounce_msg =
        \\{"t":4,"m":"dock:bounce"}
    ;
    try route(a, bounce_msg);
}
