import { ApplicationPermissions } from "../../application-permissions.zs";
import { ApplicationCapabilities } from "../../application-capabilities.zs";
import { AsyncServices } from "../../async-services.zs";
import { OnceLifetime } from "std/sync";
import { TaskScope } from "std/async";
import { thread } from "std/thread";
import { WindowManager } from "../../window.zs";
import { ApplicationMenu } from "../../application-menu.zs";
import { ClipboardManager } from "../../clipboard.zs";
import { NotificationManager } from "../../notifications.zs";
import { ShellManager } from "../../shell.zs";
import { FileManager } from "../../files.zs";
import {
  MacOSApplicationRuntime,
  initializeMacOSApplicationRuntimeState,
} from "./application-runtime.zs";
import {
  routeMessageOnMain,
} from "./message-routing.zs";
import {
  DesktopRouteMessageOperation,
} from "./document-transport.zs";

internal function initializeMacOSApplicationRuntime(
  name: String,
  permissions: ApplicationPermissions,
  capabilities: ApplicationCapabilities,
  services: AsyncServices,
  updates: TaskScope,
  windowManager: WindowManager,
  clipboard: ClipboardManager,
  notifications: NotificationManager,
  shell: ShellManager,
  files: FileManager,
  menu: ApplicationMenu
): OnceLifetime<MacOSApplicationRuntime> on thread.main {
  const route: DesktopRouteMessageOperation = routeMessageOnMain;
  return initializeMacOSApplicationRuntimeState(
    move name,
    permissions,
    capabilities,
    move services,
    updates,
    windowManager,
    clipboard,
    notifications,
    shell,
    files,
    menu,
    route
  );
}
