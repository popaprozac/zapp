import { thread } from "std/thread";
import {
  WindowManager,
  WindowOptions,
} from "../../../native/z/framework/window.zs";

export readonly class WindowService {
  readonly windows: WindowManager;

  async function openDiagnostics(): boolean on thread.main {
    let windows = this.windows;
    const created = attempt windows.create(WindowOptions({
      title: "Z Notes Diagnostics",
      url: "/diagnostics",
      inject: Array<String>("base", "diagnostics"),
      width: 480,
      height: 320,
      visible: true,
    }));
    return match (created) {
      success(_) => true;
      failure(_) => false;
    };
  }
}

export function createWindowService(
  windows: WindowManager
): WindowService on thread.main {
  return new WindowService({ windows });
}
