import { thread } from "std/thread";
import { ApplicationPaths } from "../api/zapp/service.zs";

export enum ShellOperation {
  openExternal,
  openPath,
  reveal,
  trash,
}

export struct ShellError {
  operation: ShellOperation;
  target: String;
  message: String;
}

internal type ShellOpenExternalOperation = (
  in url: String
) => void throws ShellError on thread.main;

internal type ShellPathOperation = (
  operation: ShellOperation,
  in target: String,
  in resolvedPath: String
) => void throws ShellError on thread.main;

internal type ShellAuthorizePathOperation = (
  operation: ShellOperation,
  in path: String,
  in paths: ApplicationPaths
) => String throws ShellError on thread.main;

internal struct ShellBackend {
  openExternal: ShellOpenExternalOperation;
  operateOnPath: ShellPathOperation;
  authorizePath: ShellAuthorizePathOperation;
}

function shellUnavailable(
  operation: ShellOperation,
  in target: String,
  message: String
): ShellError {
  return ShellError({
    operation,
    target: copy target,
    message: move message,
  });
}

function rejectOpenExternal(
  in url: String
): void throws ShellError on thread.main {
  throw shellUnavailable(
    ShellOperation.openExternal,
    in url,
    "shell access is unavailable before Application.run()"
  );
}

function rejectPathOperation(
  operation: ShellOperation,
  in target: String,
  in resolvedPath: String
): void throws ShellError on thread.main {
  throw shellUnavailable(
    operation,
    in target,
    "shell access is unavailable before Application.run()"
  );
}

function rejectPathAuthorization(
  operation: ShellOperation,
  in path: String,
  in paths: ApplicationPaths
): String throws ShellError on thread.main {
  throw shellUnavailable(
    operation,
    in path,
    "shell access is unavailable before Application.run()"
  );
}

function inactiveShellBackend(): ShellBackend on thread.main {
  const openExternal: ShellOpenExternalOperation = rejectOpenExternal;
  const operateOnPath: ShellPathOperation = rejectPathOperation;
  const authorizePath: ShellAuthorizePathOperation = rejectPathAuthorization;
  return ShellBackend({ openExternal, operateOnPath, authorizePath });
}

function rejectUnsupportedOpenExternal(
  in url: String
): void throws ShellError on thread.main {
  throw shellUnavailable(
    ShellOperation.openExternal,
    in url,
    "opening external URLs is unsupported by the active application platform"
  );
}

function rejectUnsupportedPathOperation(
  operation: ShellOperation,
  in target: String,
  in resolvedPath: String
): void throws ShellError on thread.main {
  throw shellUnavailable(
    operation,
    in target,
    "filesystem-backed shell operations are unsupported by the active application platform"
  );
}

function rejectUnsupportedPathAuthorization(
  operation: ShellOperation,
  in path: String,
  in paths: ApplicationPaths
): String throws ShellError on thread.main {
  throw shellUnavailable(
    operation,
    in path,
    "filesystem-backed shell operations are unsupported by the active application platform"
  );
}

internal function unsupportedShellBackend(): ShellBackend on thread.main {
  const openExternal: ShellOpenExternalOperation =
    rejectUnsupportedOpenExternal;
  const operateOnPath: ShellPathOperation = rejectUnsupportedPathOperation;
  const authorizePath: ShellAuthorizePathOperation =
    rejectUnsupportedPathAuthorization;
  return ShellBackend({ openExternal, operateOnPath, authorizePath });
}

class ShellManagerState on thread.main {
  backend: ShellBackend;
  readonly paths: ApplicationPaths;

  function openExternal(
    in url: String
  ): void throws ShellError {
    try this.backend.openExternal(in url);
  }

  function operateOnPath(
    operation: ShellOperation,
    in path: String
  ): void throws ShellError {
    const resolved = try this.backend.authorizePath(
      operation,
      in path,
      in this.paths
    );
    try this.backend.operateOnPath(
      operation,
      in path,
      in resolved
    );
  }

  function start(inout this, backend: ShellBackend): void {
    this.backend = backend;
  }

  function stop(inout this): void {
    this.backend = inactiveShellBackend();
  }
}

export readonly class ShellManager on thread.main {
  internal readonly state: ShellManagerState;

  internal constructor(in paths: ApplicationPaths) {
    this.state = new ShellManagerState({
      backend: inactiveShellBackend(),
      paths: ApplicationPaths({
        executable: copy paths.executable,
        resources: copy paths.resources,
        data: copy paths.data,
        config: copy paths.config,
        cache: copy paths.cache,
      }),
    });
  }

  function openExternal(
    in url: String
  ): void throws ShellError on thread.main {
    try this.state.openExternal(in url);
  }

  function openPath(
    in path: String
  ): void throws ShellError on thread.main {
    try this.state.operateOnPath(ShellOperation.openPath, in path);
  }

  function reveal(
    in path: String
  ): void throws ShellError on thread.main {
    try this.state.operateOnPath(ShellOperation.reveal, in path);
  }

  function trash(
    in path: String
  ): void throws ShellError on thread.main {
    try this.state.operateOnPath(ShellOperation.trash, in path);
  }

  internal function start(
    inout this,
    backend: ShellBackend
  ): void on thread.main {
    this.state.start(backend);
  }

  internal function stop(inout this): void on thread.main {
    this.state.stop();
  }
}

internal function createShellManager(
  in paths: ApplicationPaths
): ShellManager on thread.main {
  return new ShellManager(in paths);
}
