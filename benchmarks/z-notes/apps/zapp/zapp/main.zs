import { Application } from "zapp";
import { WindowOptions } from "zapp/window";
import console from "std/console";
import { thread } from "std/thread";
import { createNotesService } from "./notes-service.zs";

async function main(): i32 on thread.main {
  const app = new Application();
  const registered = attempt app.services.register(
    "notes",
    createNotesService()
  );
  match (registered) {
    success => {}
    failure(error) => {
      console.log(`service ${error.service} failed: ${error.message}`);
      return 70;
    }
  }

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
