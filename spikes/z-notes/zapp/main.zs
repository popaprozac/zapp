import { createNotesService } from "./notes-service.zs";
import { createHealthService } from "./health-service.zs";
import { Application } from "../../../native/z/api/zapp.zs";
import { WindowOptions } from "../../../native/z/api/zapp/window.zs";
import console from "std/console";
import { thread } from "std/thread";

async function main(): i32 on thread.main {
  let app = Application();
  app.services.register("notes", createNotesService());
  app.services.register("health", createHealthService());
  const createdWindow = attempt app.windows.create(WindowOptions({
    title: "Z Notes",
    url: "/notes",
    inject: Array<String>("base"),
    width: 720,
    height: 460,
  }));
  match (createdWindow) {
    success(_) => {}
    failure(error) => {
      console.log(`window ${error.id} failed: ${error.message}`);
      return 71;
    }
  }
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
