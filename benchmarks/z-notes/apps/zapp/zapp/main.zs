import { Application } from "zapp";
import { WindowOptions } from "zapp/window";
import console from "std/console";
import { thread } from "std/thread";
import { createNotesService } from "./notes-service.zs";

async function main(): i32 on thread.main {
  let app = Application();
  app.services.register("notes", createNotesService());

  const created = attempt app.windows.create(WindowOptions({
    title: "Z Notes Benchmark",
    width: 860,
    height: 600,
  }));
  match (created) {
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
      console.log("Z Notes benchmark failed");
      select 72;
    }
  };
}
