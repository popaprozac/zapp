// Presentation presets do not change the window's title or control authority.
export enum TitleBarStyle {
  default,
  hidden,
  hiddenInset,
}

export struct TitleBarOptions {
  style: TitleBarStyle = TitleBarStyle.default;
  titleVisible: boolean = true;
}
