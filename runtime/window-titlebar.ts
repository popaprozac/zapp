/** Native chrome presets. Both hidden styles retain native window controls. */
export type TitleBarStyle = "default" | "hidden" | "hiddenInset";

export interface TitleBarOptions {
  /** Default: ordinary chrome. hiddenInset adds inset native controls on macOS. */
  style?: TitleBarStyle;
  /** Default true for every style; never clears the actual window title. */
  titleVisible?: boolean;
}

/** @internal Snapshot before any asynchronous/native creation work. */
export function checkedTitleBar(value: TitleBarOptions | undefined): TitleBarOptions | undefined {
  if (value === undefined) return undefined;
  if (!value || typeof value !== "object" || Array.isArray(value)
    || Object.keys(value).some(key => key !== "style" && key !== "titleVisible")) {
    throw new TypeError("titleBar accepts only style and titleVisible.");
  }
  const { style, titleVisible } = value;
  if (style !== undefined && style !== "default" && style !== "hidden" && style !== "hiddenInset") {
    throw new TypeError("titleBar.style must be default, hidden, or hiddenInset.");
  }
  if (titleVisible !== undefined && typeof titleVisible !== "boolean") {
    throw new TypeError("titleBar.titleVisible must be a boolean.");
  }
  return { style: style ?? "default", titleVisible: titleVisible ?? true };
}
