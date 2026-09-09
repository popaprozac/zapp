import { Application, ApplicationSecondInstanceLaunchedEvent } from "zapp";
import { WindowOptions } from "zapp/window";
import { ApplicationContext, ServiceLifecycle, ServiceLifecycleError, ServiceLifecyclePhase } from "zapp/service";
import AppKit from "AppKit/AppKit.h";
import console from "std/console";
import json from "std/json";
import { thread } from "std/thread";

// Keep the service beside main: generated dispatch imports this entry's public
// declarations without creating an artificial source initialization cycle.
export readonly class StartupProbe implements ServiceLifecycle {
  fail: boolean;
  function ping(): i32 { return 42; }
  function start(in context: ApplicationContext): void throws ServiceLifecycleError on thread.main {
    console.log("service started");
    if (this.fail) throw ServiceLifecycleError({
      service: "probe", phase: ServiceLifecyclePhase.start, message: "intentional startup failure",
    });
  }
  function stop(in context: ApplicationContext): void throws ServiceLifecycleError on thread.main {
    console.log("service stopped");
  }
}

// Observe without calling sharedApplication: a secondary must not create AppKit.
function nativeApplicationCreated(): boolean = raw objc { return NSApp != nil; }

async function main(): i32 on thread.main {
  const app = new Application();
  if (app.context.arguments.length == 0) return 10;
  const mode = copy app.context.arguments[0];
  const registered = attempt app.services.register("probe", new StartupProbe({ fail: mode == "lifecycle-failure" }));
  match (registered) { success => {} failure(_) => return 11; }
  const opened = attempt app.windows.create(WindowOptions({ title: "Startup probe", url: "/", width: 320, height: 200 }));
  match (opened) { success(_) => {} failure(_) => return 12; }
  const handler: (in event: ApplicationSecondInstanceLaunchedEvent) => void on thread.main =
    move (in event: ApplicationSecondInstanceLaunchedEvent): void => {
      const encoded = json.encode(in event);
      console.log(`launch ${encoded}`);
      app.quit();
    };
  const observed = attempt app.events.secondInstanceLaunched.subscribe(handler);
  const subscription = match (observed) { success(value) => value; failure(_) => return 13; };
  const result = attempt await app.run();
  const status = match (result) {
    success(value) => value;
    failure(error) => match (error) {
      platform(_) => mode == "endpoint-failure" ? 0 : 14;
      lifecycle(_) => mode == "lifecycle-failure" ? 0 : 15;
      _ => 16;
    }
  };
  const stopped = match (app.state()) { stopped => true; _ => false; };
  console.log(`host ${nativeApplicationCreated()}`);
  console.log(`stopped ${stopped}`);
  return stopped ? status : 17;
}
