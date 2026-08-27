import {
  WindowOptions,
  createWindowManager,
} from "../framework/window.zs";
import { thread } from "std/thread";

function main(): i32 on thread.main {
  let windows = createWindowManager();
  const primary = windows.create(WindowOptions({
    title: "Primary",
    width: 720,
    height: 460,
  }));
  const secondary = windows.create(WindowOptions());

  if (primary.id != "win-1" || secondary.id != "win-2") return 1;
  const initial = windows.all();
  if (initial.length != 2) return 2;

  const found = windows.get(primary.id);
  const foundId = match (found) {
    some(window) => copy window.id;
    none => "";
  };
  if (foundId != "win-1") return 3;

  primary.hide();
  const hidden = windows.__options(primary.id);
  const isHidden = match (hidden) {
    some(options) => !options.visible;
    none => false;
  };
  if (!isHidden) return 4;

  primary.show();
  primary.setTitle("Renamed");
  const updated = windows.__options(primary.id);
  const matches = match (updated) {
    some(options) => options.visible && options.title == "Renamed";
    none => false;
  };
  if (!matches) return 5;

  primary.close();
  primary.close();
  const remaining = windows.all();
  if (remaining.length != 1) return 6;
  return match (windows.get(primary.id)) {
    some(_) => 7;
    none => 0;
  };
}
