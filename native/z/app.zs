import { createNotesService } from "./notes-service.zs";
import { Application } from "./desktop-core.zs";

function main(): i32 {
  let app = Application({ name: "Notes" });
  app.services.register("notes", createNotesService());
  return app.run();
}
