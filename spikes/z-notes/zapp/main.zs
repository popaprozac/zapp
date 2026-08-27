import { createNotesService } from "./notes-service.zs";
import { createHealthService } from "./health-service.zs";
import { Application } from "../../../native/z/framework/application.zs";
import { WindowOptions } from "../../../native/z/framework/window.zs";
import console from "std/console";
import { thread } from "std/thread";

async function main(): i32 on thread.main {
  let app = Application();
  app.services.register("notes", createNotesService());
  app.services.register("health", createHealthService());
  const mainWindow = app.windows.create(WindowOptions({
    title: "Z Notes",
    url: "/notes",
    width: 720,
    height: 460,
  }));
  const result = attempt await app.run();
  return match (result) {
    success(status) => status;
    failure(error) => {
      const exitStatus = match (error) {
        lifecycle(lifecycleError) => {
          match (lifecycleError.phase) {
            start => console.log(
              `service ${lifecycleError.service} failed during start: ${lifecycleError.message}`
            );
            stop => console.log(
              `service ${lifecycleError.service} failed during stop: ${lifecycleError.message}`
            );
          }
          select 70;
        }
        window(windowError) => {
          console.log(`window ${windowError.id} failed: ${windowError.message}`);
          select 71;
        }
        platform(platformError) => {
          console.log(
            `platform error ${platformError.code}: ${platformError.message}`
          );
          select 72;
        }
      };
      select exitStatus;
    }
  };
}
