const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("probe.h");
});

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Zig 0.16.0 reworked file IO around an explicit `Io` interface (the
    // "writergate"/IO-as-interface redesign). `std.fs.cwd()` moved to
    // `std.Io.Dir.cwd()`, and `readFileAlloc` now takes an `Io` provider and an
    // `Io.Limit` (instead of the old `(allocator, path, max_size)` shape).
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const text = try std.Io.Dir.cwd().readFileAlloc(
        io, "spikes/lang-eval/shared/sample.json", a, .limited(1 << 16));
    const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    const obj = parsed.value.object;
    const w: c_int = @intCast(obj.get("w").?.integer);
    const h: c_int = @intCast(obj.get("h").?.integer);
    // C wants NUL-terminated; std.json strings are slices — dupeZ.
    const title = try a.dupeZ(u8, obj.get("title").?.string);

    if (builtin.os.tag == .macos) {
        c.spike_cocoa_open_window(w, h, title.ptr);
    } else {
        c.spike_print_windows();
    }
}
