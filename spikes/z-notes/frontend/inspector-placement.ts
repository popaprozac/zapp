import type { Bounds, WindowPosition } from "@zappdev/runtime/window";

// Notes policy, not a framework default: prefer right, then left, then overlap
// as necessary to keep the inspector inside the owner's current work area.
export function inspectorPosition(owner: Bounds, inspector: Bounds, workArea: Bounds): WindowPosition {
  const gap = 12;
  const right = owner.x + owner.width + gap;
  const left = owner.x - inspector.width - gap;
  const edge = workArea.x + workArea.width;
  const preferred = right + inspector.width <= edge ? right : left >= workArea.x ? left : right;
  return {
    x: Math.max(workArea.x, Math.min(preferred, edge - inspector.width)),
    y: Math.max(workArea.y, Math.min(owner.y, workArea.y + workArea.height - inspector.height)),
  };
}
