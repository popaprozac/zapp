import { Map } from "std/collections";
import {
  ApplicationCapabilities,
  CapabilityProfile,
} from "./application-capabilities.zs";
import { ApplicationMetadata } from "./application-metadata.zs";
import { ApplicationPermissions } from "./application-permissions.zs";
import {
  ApplicationWorkerCatalog,
  emptyApplicationWorkerCatalog,
} from "./worker/configuration.zs";

// The CLI replaces this module only inside its isolated build workspace.
// Keeping a deterministic fallback in the source graph preserves editor,
// direct-check, and focused-smoke behavior outside a Zapp build.
export function configuredApplicationMetadata(): ApplicationMetadata {
  return ApplicationMetadata({
    name: "Zapp",
    identifier: "com.zapp.app",
    version: "0.1.0",
  });
}

export function configuredApplicationPermissions(): ApplicationPermissions {
  return ApplicationPermissions({
    windowCreate: true,
  });
}

export function configuredApplicationCapabilities(): ApplicationCapabilities {
  let permissions = Array<String>("window:create");
  let services = Array<String>();
  let profiles = Map<String, CapabilityProfile>();
  profiles.set("default", CapabilityProfile({
    permissions: permissions.freeze(),
    serviceMethods: services.freeze(),
  }));
  return new ApplicationCapabilities({ profiles: profiles.freeze() });
}

export function configuredApplicationWorkers(): ApplicationWorkerCatalog {
  return emptyApplicationWorkerCatalog();
}
