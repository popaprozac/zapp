import { ApplicationConfig } from "./application-contract.zs";
import {
  runApplicationPlatform as runHeadlessApplicationPlatform,
} from "./platform/headless.zs";
import { createServices } from "./services.zs";
import { createServiceLifecycles } from "./service-lifecycle.zs";

function main(): i32 {
  const config = ApplicationConfig({
    name: "Headless",
    services: createServices().freeze(),
    lifecycles: createServiceLifecycles().freeze(),
  });
  const result = attempt runHeadlessApplicationPlatform(move config);
  return match (result) {
    success(status) => status;
    failure(_) => 70;
  };
}
