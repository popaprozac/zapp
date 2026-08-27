import { ApplicationMetadata } from "./application-metadata.zs";

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
