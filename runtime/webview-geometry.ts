// Pure geometry for embedded webviews — no DOM/native deps so it unit-tests
// under bun:test. The host WKWebView fills the window content view 1:1 at
// zoom 1, so contentHeight ≈ window.innerHeight and CSS px ≈ native points.

export interface NativeRect { x: number; y: number; w: number; h: number; }

/**
 * Convert a DOMRect-like (CSS px, viewport top-left origin) to native
 * content-view points (macOS bottom-left origin). Rounded to whole points
 * (WKWebView setFrame wants integers; subpixel frames blur the embed).
 */
export function toNativeRect(
  rect: { left: number; top: number; width: number; height: number },
  contentHeight: number,
): NativeRect {
  return {
    x: Math.round(rect.left),
    y: Math.round(contentHeight - rect.top - rect.height),
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
