import type { BuildTarget } from "./native";

export interface SwiftUIBuildPlan {
  /** SwiftUI is compiled in for this build. */
  enabled: boolean;
  /** Whether buildNativeNim should run the swiftc step. */
  runSwiftc: boolean;
  /** Why (for the build log line). */
  reason: "enabled" | "disabled-opt-out" | "skipped-no-swiftc" | "non-macos";
  /** Extra `nim c` args to append when enabled (defines + passC + passL). Empty when disabled. */
  nimArgs: string[];
}

/**
 * Decide whether/how SwiftUI is compiled into this build. Pure — no I/O.
 * Apple enhanced-tier gate (macOS only this cycle):
 *   enabled  ⇔ target == macos AND swiftc present AND not opted out.
 * When enabled, emit the Nim defines + the proven Swift link flags
 * (see spikes/swiftui-nim/FINDINGS.md — the load-bearing pieces are the SDK
 * .tbd stubs for -lswiftCore/-lswiftFoundation plus -rpath /usr/lib/swift).
 */
export function resolveSwiftUIBuild(opts: {
  target: BuildTarget;
  swiftuiConfig: boolean | undefined; // config.native?.swiftui
  swiftcAvailable: boolean;
  swiftLibDir: string; // dir that will hold libzappswift.a (for -L)
}): SwiftUIBuildPlan {
  const { target, swiftuiConfig, swiftcAvailable, swiftLibDir } = opts;

  if (target !== "macos") return { enabled: false, runSwiftc: false, reason: "non-macos", nimArgs: [] };
  if (swiftuiConfig === false) return { enabled: false, runSwiftc: false, reason: "disabled-opt-out", nimArgs: [] };
  if (!swiftcAvailable) return { enabled: false, runSwiftc: false, reason: "skipped-no-swiftc", nimArgs: [] };

  // AppKit comes in via -framework Cocoa already; only add SwiftUI here.
  // Drop the cosmetic toolchain -rpath (FINDINGS): lean on SDK .tbd + /usr/lib/swift.
  const link =
    `-L${swiftLibDir} -lzappswift -lswiftCore -lswiftFoundation ` +
    `-Xlinker -rpath -Xlinker /usr/lib/swift -framework SwiftUI`;

  return {
    enabled: true,
    runSwiftc: true,
    reason: "enabled",
    nimArgs: ["-d:zappSwiftUI", "--passC:-DZAPP_HAS_SWIFTUI", `--passL:${link}`],
  };
}
