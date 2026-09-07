// Permissions manifest — the v1 app-global allow/deny catalog.
// Spec: docs/superpowers/specs/2026-06-09-permissions-system-design.md
//
// Ids are module names with an optional verb. A bare module name grants
// all of its verbs ("clipboard" ⊇ "clipboard:read" + "clipboard:write").
// The union type gives editors autocomplete + typo errors in zapp.config.ts.

import { clogError } from "./log";

export type ZappPermission =
  | "application:quit"
  | "clipboard" | "clipboard:read" | "clipboard:write"
  | "fs" | "fs:read" | "fs:write"
  | "dialog"
  | "notifications"
  | "shortcuts"
  | "tray"
  | "dock"
  | "menu"
  | "screen"
  | "embed"
  | "window:create"
  | "shell" | "shell:open" | "shell:reveal" | "shell:trash";

export const PERMISSION_IDS: readonly ZappPermission[] = [
  "application:quit",
  "clipboard", "clipboard:read", "clipboard:write",
  "fs", "fs:read", "fs:write",
  "dialog", "notifications", "shortcuts", "tray", "dock", "menu",
  "screen", "embed", "window:create",
  "shell", "shell:open", "shell:reveal", "shell:trash",
];

export interface ResolvedPermissions {
  /** false when the config field is absent — allow-all (legacy behavior). */
  active: boolean;
  /** Deduped, order-preserving allowlist. Empty + active=true → deny-all. */
  allow: ZappPermission[];
}

export function resolvePermissions(field: ZappPermission[] | undefined): ResolvedPermissions {
  if (field === undefined) return { active: false, allow: [] };
  return { active: true, allow: [...new Set(field)] };
}

/** Levenshtein distance for did-you-mean suggestions (small inputs only). */
function editDistance(a: string, b: string): number {
  const m = a.length, n = b.length;
  const d = Array.from({ length: m + 1 }, (_, i) => [i, ...Array(n).fill(0)]);
  for (let j = 0; j <= n; j++) d[0][j] = j;
  for (let i = 1; i <= m; i++)
    for (let j = 1; j <= n; j++)
      d[i][j] = Math.min(
        d[i - 1][j] + 1, d[i][j - 1] + 1,
        d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1),
      );
  return d[m][n];
}

/**
 * Returns build-blocking errors (unknown ids). Redundant entries (a verb
 * listed alongside its bare module) only warn on stderr — harmless.
 */
export function validatePermissions(field: ZappPermission[] | undefined): string[] {
  if (field === undefined) return [];
  const errors: string[] = [];
  const set = new Set<string>(field);
  for (const id of new Set(field)) {
    if (!PERMISSION_IDS.includes(id)) {
      const best = [...PERMISSION_IDS]
        .sort((x, y) => editDistance(id, x) - editDistance(id, y))[0];
      const dist = editDistance(id, best);
      errors.push(
        dist <= 3
          ? `[zapp] unknown permission "${id}" — did you mean "${best}"?`
          : `[zapp] unknown permission "${id}". Valid permissions: ${PERMISSION_IDS.join(", ")}`,
      );
      continue;
    }
    const colon = id.indexOf(":");
    if (colon > 0 && set.has(id.slice(0, colon))) {
      clogError(
        `permissions: "${id}" is redundant — bare "${id.slice(0, colon)}" already grants it`,
      );
    }
  }
  return errors;
}

/** Verb semantics shared with native permissions.zc — keep in lockstep. */
export function isPermissionAllowed(id: string, resolved: ResolvedPermissions): boolean {
  if (!resolved.active) return true;
  if (resolved.allow.includes(id as ZappPermission)) return true;
  const colon = id.indexOf(":");
  if (colon > 0 && resolved.allow.includes(id.slice(0, colon) as ZappPermission)) return true;
  return false;
}
