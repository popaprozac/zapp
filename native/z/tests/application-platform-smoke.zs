import { PreparedApplication } from "../framework/application-contract.zs";
import { ApplicationMetadata } from "../framework/application-metadata.zs";
import { ApplicationPermissions } from "../framework/application-permissions.zs";
import { Map } from "std/collections";
import { ApplicationCapabilities, CapabilityProfile } from "../framework/application-capabilities.zs";
import {
  runApplicationPlatform as runHeadlessApplicationPlatform,
} from "../framework/platform/headless.zs";
import { createAsyncServices } from "../framework/async-services.zs";
import { createServiceLifecycles } from "../framework/service-lifecycle.zs";
import { createWindowManager } from "../framework/window.zs";
import { createDialogManager } from "../framework/dialog.zs";
import { createClipboardManager } from "../framework/clipboard.zs";
import { createNotificationManager } from "../framework/notifications.zs";
import { createShellManager } from "../framework/shell.zs";
import {
  createFilesystemAuthority,
} from "../framework/filesystem-authority.zs";
import { createApplicationMenu } from "../framework/application-menu.zs";
import { emptyApplicationWorkerCatalog } from "../framework/worker/configuration.zs";
import { createWorkerManager } from "../framework/worker/worker-manager.zs";
import { createApplicationEvents } from "../framework/application-events.zs";
import { createFileManager } from "../framework/files.zs";
import {
  ApplicationContext,
  ApplicationPaths,
} from "../api/zapp/service.zs";
import { TaskScope } from "std/async";
import { thread } from "std/thread";

async function main(): i32 on thread.main {
  let profiles = Map<String, CapabilityProfile>();
  let arguments = Array<String>();
  let services = createAsyncServices();
  let lifecycles = createServiceLifecycles();
  const filesystemPaths = ApplicationPaths({
    executable: "/tmp/zapp-headless",
    resources: "/tmp",
    data: "/tmp/zapp-headless/data",
    config: "/tmp/zapp-headless/config",
    cache: "/tmp/zapp-headless/cache",
  });
  const filesystemAuthority = createFilesystemAuthority(in filesystemPaths);
  const shell = createShellManager(filesystemAuthority);
  const files = createFileManager(filesystemAuthority);
  const config = new PreparedApplication({
    metadata: ApplicationMetadata({
      name: "Headless",
      identifier: "com.zapp.headless",
      version: "0.1.0",
    }),
    context: ApplicationContext({
      metadata: ApplicationMetadata({
        name: "Headless",
        identifier: "com.zapp.headless",
        version: "0.1.0",
      }),
      arguments: arguments.freeze(),
      paths: ApplicationPaths({
        executable: "/tmp/zapp-headless",
        resources: "/tmp",
        data: "/tmp/zapp-headless/data",
        config: "/tmp/zapp-headless/config",
        cache: "/tmp/zapp-headless/cache",
      }),
    }),
    permissions: ApplicationPermissions(),
    capabilities: new ApplicationCapabilities({
      profiles: profiles.freeze(),
    }),
    events: createApplicationEvents(),
    windows: createWindowManager(),
    dialogs: createDialogManager(filesystemAuthority),
    clipboard: createClipboardManager(),
    notifications: createNotificationManager(),
    filesystemAuthority,
    shell,
    files,
    menu: createApplicationMenu(),
    services: services.freeze(),
    lifecycles: lifecycles.freeze(),
    workers: createWorkerManager(emptyApplicationWorkerCatalog()),
  });
  const updates = new TaskScope();
  const result = attempt await runHeadlessApplicationPlatform(
    config,
    updates
  );
  return match (result) {
    success(status) => status;
    failure(_) => 70;
  };
}
