import Foundation

// Phase 2 vertical slice — reimplements one real Zapp path (mirrors
// `router_handle_window_action`) to grade ergonomics on the patterns we actually
// use: bridge-JSON → route on `m` → window create, a platform-gated action, a
// struct+method, const-correctness threading, and the raw→.m-wrapper architecture
// (no inline ObjC in the orchestration lang).

// (3) A struct + method — the WindowOptions-like value object.
struct WindowOptions {
    let w: Int32
    let h: Int32
    let title: String

    // (5) raw→wrapper: the ObjC that sets `win.title` lives in probe_cocoa.m
    // behind the plain C `spike_cocoa_open_window`. apply() just forwards — ZERO
    // inline ObjC in Swift. (4) Const-correctness: Swift bridges the immutable
    // `title` String to the C `const char*` automatically for the call — no
    // manual NUL-termination, no cast wrangling, no discard-qualifier fights.
    func apply() {
        spike_cocoa_open_window(w, h, title)
    }
}

// (1) Codable bridge-frame shapes. `a` is Optional — present only for
// window:create; JSONDecoder fills it with nil when absent (no raise), while a
// MISSING required key on a frame that needs it throws a catchable error. This is
// the most robust JSON of the set: typed, explicit optionals, errors you catch
// (vs Zig `.get(k).?` trap / Nim `[]` raise).
struct BridgeMsg: Codable {
    let t: Int
    let m: String
    let a: WindowArgs?
}
struct WindowArgs: Codable {
    let w: Int32
    let h: Int32
    let title: String
}

// (1)+(3)+(4) window:create handler — build the struct, .apply().
func handleWindowCreate(_ args: WindowArgs) {
    WindowOptions(w: args.w, h: args.h, title: args.title).apply()
}

// (2) platform-gated action — COMPILE-TIME #if branch; the dead branch is elided
// (the linker never sees `spike_print_windows` on macOS). No emit footgun and no
// per-platform-stub obligation like Zen-C `@cfg` (which forces a twin fn).
func handleDockBounce() {
    #if os(macOS)
    spike_cocoa_beep()
    #else
    spike_print_windows()
    #endif
}

// The router — native Swift string `switch`, exhaustive-by-shape with a `default`.
// The slice's analogue of `router_handle_window_action`.
func route(_ msg: String) throws {
    let frame = try JSONDecoder().decode(BridgeMsg.self, from: Data(msg.utf8))
    switch frame.m {
    case "window:create":
        if let a = frame.a { handleWindowCreate(a) }
    case "dock:bounce":
        handleDockBounce()
    default:
        print("[slice] unrouted message: \(frame.m)")
    }
}

// (1) Bridge JSON → route → window create.
try route(#"{"t":4,"m":"window:create","a":{"w":700,"h":500,"title":"slice"}}"#)
// (2) platform-gated action.
try route(#"{"t":4,"m":"dock:bounce"}"#)
