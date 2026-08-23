import { ApplicationConfig } from "./application-contract.zs";
import { runApplicationPlatform } from "./platform.zs";
import { ServicesBuilder, createServices } from "./services.zs";
import { thread } from "std/thread";

export struct Application {
  name: String;
  services: ServicesBuilder = createServices();

  function run(move this): i32 on thread.main {
    const { name, services } = move this;
    const config = ApplicationConfig({
      name: move name,
      services: services.freeze(),
    });
    return runApplicationPlatform(move config);
  }
}
