import { ApplicationConfig } from "../framework/application-contract.zs";
import {
  runApplicationPlatform as runHeadlessApplicationPlatform,
} from "../framework/platform/headless.zs";
import { createServices } from "../framework/services.zs";
import { createServiceLifecycles } from "../framework/service-lifecycle.zs";

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
