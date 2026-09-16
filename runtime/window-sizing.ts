/** @internal Shared numeric validation; native independently enforces limits. */
export interface SizeOptions {
  width?: number;
  height?: number;
  minWidth?: number;
  minHeight?: number;
  maxWidth?: number;
  maxHeight?: number;
}

export function positiveDimension(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value > 0 && value <= 0xffff_ffff;
}

export function checkSizeOptions(options: SizeOptions): void {
  for (const key of ["width", "height", "minWidth", "minHeight", "maxWidth", "maxHeight"] as const) {
    if (options[key] !== undefined && !positiveDimension(options[key])) {
      throw new TypeError(`Window ${key} must be a positive u32 integer in logical units.`);
    }
  }
  if ((options.minWidth ?? 1) > (options.maxWidth ?? 0xffff_ffff)
    || (options.minHeight ?? 1) > (options.maxHeight ?? 0xffff_ffff)) {
    throw new TypeError("Window minimum size must not exceed maximum size.");
  }
}
