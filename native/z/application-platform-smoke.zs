import { ApplicationConfig } from "./application-contract.zs";
import {
  runApplicationPlatform as runHeadlessApplicationPlatform,
} from "./platform/headless.zs";
import { createServices } from "./services.zs";

function main(): i32 {
  const config = ApplicationConfig({
    name: "Headless",
    services: createServices().freeze(),
  });
  return runHeadlessApplicationPlatform(move config);
}
