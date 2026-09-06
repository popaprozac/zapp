import { thread } from "std/thread";
import { ApplicationPaths } from "../api/zapp/service.zs";
import {
  configuredFilesystemAllowAtIndex,
} from "./configured-filesystem.zs";

// Nominal evidence that one application-owned authority has canonicalized a
// path and found it inside the compiled resource boundary. This type never
// enters the public Zapp API and cannot be forged by a WebView caller.
internal readonly struct AuthorizedPath {
  resolved: String;
}

internal struct FilesystemAuthorityError {
  target: String;
  message: String;
}

internal type FilesystemCanonicalizeOperation = (
  in source: String,
  in paths: ApplicationPaths
) => Option<String> throws FilesystemAuthorityError on thread.main;

internal type FilesystemContainsOperation = (
  in path: String,
  in root: String
) => boolean on thread.main;

internal struct FilesystemAuthorityBackend {
  canonicalize: FilesystemCanonicalizeOperation;
  contains: FilesystemContainsOperation;
}

function unavailableFilesystemCanonicalization(
  in source: String,
  in paths: ApplicationPaths
): Option<String> throws FilesystemAuthorityError on thread.main {
  throw FilesystemAuthorityError({
    target: copy source,
    message: "filesystem authority is unavailable before Application.run()",
  });
}

function unsupportedFilesystemCanonicalization(
  in source: String,
  in paths: ApplicationPaths
): Option<String> throws FilesystemAuthorityError on thread.main {
  throw FilesystemAuthorityError({
    target: copy source,
    message: "filesystem-backed operations are unsupported by the active application platform",
  });
}

function unavailableFilesystemContainment(
  in path: String,
  in root: String
): boolean on thread.main {
  return false;
}

function inactiveFilesystemAuthorityBackend(
): FilesystemAuthorityBackend on thread.main {
  const canonicalize: FilesystemCanonicalizeOperation =
    unavailableFilesystemCanonicalization;
  const contains: FilesystemContainsOperation =
    unavailableFilesystemContainment;
  return FilesystemAuthorityBackend({ canonicalize, contains });
}

internal function unsupportedFilesystemAuthorityBackend(
): FilesystemAuthorityBackend on thread.main {
  const canonicalize: FilesystemCanonicalizeOperation =
    unsupportedFilesystemCanonicalization;
  const contains: FilesystemContainsOperation =
    unavailableFilesystemContainment;
  return FilesystemAuthorityBackend({ canonicalize, contains });
}

class FilesystemAuthorityState on thread.main {
  backend: FilesystemAuthorityBackend;
  readonly paths: ApplicationPaths;

  function authorize(
    in source: String
  ): AuthorizedPath throws FilesystemAuthorityError {
    const resolved = try this.backend.canonicalize(in source, in this.paths);
    const path = match (resolved) {
      some(value) => value;
      none => throw FilesystemAuthorityError({
        target: copy source,
        message: `invalid filesystem path "${source}"`,
      });
    };
    let index: usize = 0;
    while (true) {
      const configured = configuredFilesystemAllowAtIndex(index);
      const rootSource = match (configured) {
        some(value) => value;
        none => throw FilesystemAuthorityError({
          target: copy source,
          message: `filesystem path "${source}" is outside the authority declared by security.filesystem.allow`,
        });
      };
      const resolvedRoot = try this.backend.canonicalize(
        in rootSource,
        in this.paths
      );
      match (resolvedRoot) {
        some(root) => {
          if (this.backend.contains(in path, in root)) {
            return AuthorizedPath({ resolved: path });
          }
        }
        none => {}
      }
      index = index + 1;
    }
    throw FilesystemAuthorityError({
      target: copy source,
      message: `filesystem path "${source}" is outside the authority declared by security.filesystem.allow`,
    });
  }

  function start(
    inout this,
    backend: FilesystemAuthorityBackend
  ): void {
    this.backend = backend;
  }

  function stop(inout this): void {
    this.backend = inactiveFilesystemAuthorityBackend();
  }
}

internal readonly class FilesystemAuthority on thread.main {
  internal readonly state: FilesystemAuthorityState;

  internal constructor(in paths: ApplicationPaths) {
    this.state = new FilesystemAuthorityState({
      backend: inactiveFilesystemAuthorityBackend(),
      paths: ApplicationPaths({
        executable: copy paths.executable,
        resources: copy paths.resources,
        data: copy paths.data,
        config: copy paths.config,
        cache: copy paths.cache,
      }),
    });
  }

  internal function authorize(
    in path: String
  ): AuthorizedPath throws FilesystemAuthorityError on thread.main {
    return try this.state.authorize(in path);
  }

  internal function start(
    inout this,
    backend: FilesystemAuthorityBackend
  ): void on thread.main {
    this.state.start(backend);
  }

  internal function stop(inout this): void on thread.main {
    this.state.stop();
  }
}

internal function createFilesystemAuthority(
  in paths: ApplicationPaths
): FilesystemAuthority on thread.main {
  return new FilesystemAuthority(in paths);
}
