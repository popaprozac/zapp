/**
 * Permissions — query the app's declarative native-capability manifest
 * (`permissions` in zapp.config.ts) and the platform's support for a
 * capability, in one tri-state answer.
 *
 * ```ts
 * import { Permissions } from "@zappdev/runtime";
 * await Permissions.query("clipboard:write"); // "granted" | "denied" | "unsupported"
 * ```
 *
 * Enforcement is NATIVE — these mirrors exist for fast, friendly errors
 * and detection; a handcrafted bridge message still hits the native gate.
 */
import { getBridge } from "./bridge";

export type PermissionState = "granted" | "denied" | "unsupported";

export interface PermissionsManifest {
  platform: string;          // "macos" | "ios" | "windows"
  active: boolean;           // false = no permissions field (allow-all)
  allow: string[];
}

export class PermissionDeniedError extends Error {
  readonly code = "PERMISSION_DENIED" as const;
  constructor(readonly permission: string) {
    super(
      `[zapp] permission denied: "${permission}" — add it to \`permissions\` in zapp.config.ts`,
    );
    this.name = "PermissionDeniedError";
  }
}

/** Verb semantics — keep in lockstep with native permissions.zc and cli/src/permissions.ts. */
export function isAllowedByManifest(id: string, manifest: PermissionsManifest | undefined): boolean {
  if (!manifest || !manifest.active) return true;
  if (manifest.allow.includes(id)) return true;
  const colon = id.indexOf(":");
  if (colon > 0 && manifest.allow.includes(id.slice(0, colon))) return true;
  return false;
}

// Platform support matrix (v1: static; the native parity audit keeps it
// honest). Keyed by bare module — verbs resolve through their module.
// "windows" entries reflect the current partial port.
const UNSUPPORTED: Record<string, string[]> = {
  ios: ["tray", "menu", "shortcuts", "dock", "shell"],
  windows: ["clipboard", "tray", "dock", "embed", "notifications", "shell", "screen"],
  macos: [],
};

export function supportStatus(id: string, platform: string): "supported" | "unsupported" {
  const colon = id.indexOf(":");
  const module = colon > 0 ? id.slice(0, colon) : id;
  const list = UNSUPPORTED[platform] ?? [];
  return list.includes(module) ? "unsupported" : "supported";
}

function bootstrapManifest(): PermissionsManifest | undefined {
  return (globalThis as any)[Symbol.for("zapp.bootstrapConfig")]?.permissions;
}

let cached: PermissionsManifest | undefined;

async function manifest(): Promise<PermissionsManifest | undefined> {
  if (cached) return cached;
  const boot = bootstrapManifest();
  if (boot) { cached = boot; return cached; }
  try {
    cached = await (getBridge().invoke("__zapp:permissions", {}) as Promise<PermissionsManifest>);
  } catch {
    cached = undefined;
  }
  return cached;
}

/**
 * Synchronous manifest check for fire-and-forget runtime calls (Tray.create,
 * Dock.*, Menu.build, …). Webview-only fast path via the bootstrap config; in
 * workers (no synchronous manifest) it does not throw — native still enforces.
 */
export function ensurePermission(id: string): void {
  const boot = bootstrapManifest();
  if (boot && !isAllowedByManifest(id, boot)) throw new PermissionDeniedError(id);
}

/** Detects the native deny reply and rethrows it typed. */
export function rethrowPermissionError(e: unknown): never {
  const msg = e instanceof Error ? e.message : String(e);
  if (msg.startsWith("PERMISSION_DENIED:")) {
    throw new PermissionDeniedError(msg.slice("PERMISSION_DENIED:".length));
  }
  throw e;
}

export const Permissions = {
  async query(id: string): Promise<PermissionState> {
    const m = await manifest();
    const platform = m?.platform ?? bootstrapManifest()?.platform ?? "macos";
    if (supportStatus(id, platform) === "unsupported") return "unsupported";
    return isAllowedByManifest(id, m) ? "granted" : "denied";
  },
  async list(): Promise<string[]> {
    const m = await manifest();
    return m?.active ? [...m.allow] : [];
  },
};
