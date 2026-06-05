/**
 * Screen — enumerate displays + their geometry. All coordinates are
 * TOP-LEFT GLOBAL (origin at the primary display's top-left, y down),
 * matching Window.setPosition/getPosition, so a window can be placed on a
 * display by its bounds. Async (queries native each call); subscribe to
 * AppEvent.SCREENS_CHANGED to re-query on monitor plug/unplug.
 */
import { getBridge } from "./bridge";

export interface DisplayRect { x: number; y: number; width: number; height: number; }

export interface Display {
  id: string;
  name: string;
  bounds: DisplayRect;
  workArea: DisplayRect;
  scaleFactor: number;
  isPrimary: boolean;
  rotation: 0 | 90 | 180 | 270;
}

export interface CursorPoint { x: number; y: number; display: Display; }

// invoke() may return an already-parsed object or a JSON string depending on
// payload; coerce defensively either way.
function coerce<T>(r: unknown): T {
  return (typeof r === "string" ? JSON.parse(r) : r) as T;
}

// Pure (unit-tested) selectors over a display list. ---
export function findPrimary(displays: Display[]): Display | null {
  return displays.find((d) => d.isPrimary) ?? displays[0] ?? null;
}
export function findById(displays: Display[], id: string): Display | null {
  return displays.find((d) => d.id === id) ?? null;
}

async function getAll(): Promise<Display[]> {
  return coerce<Display[]>(await getBridge().invoke("__screen:list")) ?? [];
}

export const Screen = {
  /** All connected displays. */
  getAll,
  /** The primary (menu-bar) display, or null if none. */
  async getPrimary(): Promise<Display | null> {
    return findPrimary(await getAll());
  },
  /** A display by id, or null if not found. */
  async getById(id: string): Promise<Display | null> {
    return findById(await getAll(), id);
  },
  /** Current mouse location + the display it's on. (macOS; iOS returns {0,0}.) */
  async getCursorPoint(): Promise<CursorPoint> {
    return coerce<CursorPoint>(await getBridge().invoke("__screen:cursor"));
  },
};
