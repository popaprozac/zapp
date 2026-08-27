import { createNotesService } from "./notes-service.zs";
import { createHealthService } from "./health-service.zs";
import { Application } from "../../../native/z/framework/application.zs";
import console from "std/console";
import { thread } from "std/thread";

async function main(): i32 on thread.main {
  let app = Application();
  app.services.register("notes", createNotesService());
  app.services.register("health", createHealthService());
  const result = attempt await app.run();
  return match (result) {
    success(status) => status;
    failure(error) => {
      match (error.phase) {
        start => console.log(
          `service ${error.service} failed during start: ${error.message}`
        );
        stop => console.log(
          `service ${error.service} failed during stop: ${error.message}`
        );
      }
      select 70;
    }
  };
}
