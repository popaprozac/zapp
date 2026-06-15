import Foundation

// Swift probe — same contract as the others: read shared/sample.json, parse it,
// open an NSWindow through the plain-C-ABI wrapper in probe_cocoa.o. The C header
// is consumed via the bridging header (-import-objc-header probe.h), so
// spike_cocoa_open_window is callable directly with no binding boilerplate — and
// Swift's ObjC/C interop is native (no C-ABI shim would even be needed; this
// probe keeps probe_cocoa.o only to hold the size variable constant vs the field).

// Idiomatic Swift JSON: a Codable struct + JSONDecoder (Foundation's stdlib JSON,
// type-safe, throwing on mismatch — no dictionary spelunking).
struct Config: Codable {
    let w: Int32
    let h: Int32
    let title: String
}

let path = "spikes/lang-eval/shared/sample.json"
let data = try Data(contentsOf: URL(fileURLWithPath: path))
let cfg = try JSONDecoder().decode(Config.self, from: data)

// Platform branch — compile-time #if, dead branch fully elided like the others.
#if os(macOS)
// `cfg.title` is a Swift String; Swift auto-bridges it to the C `const char*`
// for the duration of the call — no manual NUL-termination (unlike Zig dupeZ /
// Zen-C .cstring / C strdup).
spike_cocoa_open_window(cfg.w, cfg.h, cfg.title)
#else
spike_print_windows()
#endif
