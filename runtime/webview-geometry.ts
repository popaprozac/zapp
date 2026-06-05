// Pure geometry for embedded webviews — no DOM/native deps so it unit-tests
// under bun:test.

export interface NativeRect { x: number; y: number; w: number; h: number; }

/**
 * Round a DOMRect-like (CSS px, viewport TOP-LEFT origin) to whole-point
 * integers. The top-left → native-origin flip is done NATIVE-side in
 * panel.m using the actual superview's `isFlipped` + bounds (WKWebView is
 * flipped/top-left), which avoids the unreliable window.innerHeight
 * assumption. So this stays a pure top-left rounder.
 */
export function toNativeRect(
  rect: { left: number; top: number; width: number; height: number },
): NativeRect {
  return {
    x: Math.round(rect.left),
    y: Math.round(rect.top),
    w: Math.round(rect.width),
    h: Math.round(rect.height),
  };
}

/** Equal in all four fields. null only equals null. Used to skip redundant posts. */
export function rectsEqual(a: NativeRect | null, b: NativeRect | null): boolean {
  if (a === null || b === null) return a === b;
  return a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h;
}

/** Non-zero area. A 0-area rect means display:none / detached → hide the panel. */
export function isVisibleRect(rect: { width: number; height: number }): boolean {
  return rect.width > 0 && rect.height > 0;
}
