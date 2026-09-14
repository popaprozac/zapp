import json from "std/json";
import { TitleBarOptions, TitleBarStyle } from "./window-titlebar.zs";

internal readonly struct FrontendTitleBarOptions {
  style: String = "default";
  titleVisible: boolean = true;
}

// Derived decoding rejects wrong value types; separately reject misspelled or
// future facts rather than silently ignoring a requested appearance option.
internal function validTitleBarFields(in source: String): boolean {
  const value = match (attempt json.parse(in source)) {
    success(value) => value;
    failure(_) => return false;
  };
  return match (in value) {
    object(fields) => {
      for (const field of fields) {
        if (field.key != "titleBar") continue;
        match (in field.value) {
          object(options) => {
            for (const option of options) {
              if (option.key != "style" && option.key != "titleVisible") return false;
            }
          }
          _ => return false;
        }
      }
      select true;
    }
    _ => false;
  };
}

internal function checkedTitleBar(in options: FrontendTitleBarOptions): TitleBarOptions throws String {
  let style = TitleBarStyle.default;
  if (options.style == "hidden") style = TitleBarStyle.hidden;
  else if (options.style == "hiddenInset") style = TitleBarStyle.hiddenInset;
  else if (options.style != "default") throw "titleBar.style must be default, hidden, or hiddenInset";
  return TitleBarOptions({ style, titleVisible: options.titleVisible });
}
