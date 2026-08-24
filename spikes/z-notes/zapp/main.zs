import { createNotesService } from "./notes-service.zs";
import { Application } from "../../../native/z/framework/application.zs";
import console from "std/console";

function main(): i32 {
  let app = Application({ name: "Notes" });
  app.services.register("notes", createNotesService());
  const result = attempt app.run();
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
