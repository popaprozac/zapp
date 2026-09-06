import { thread } from "std/thread";
import {
  AuthorizedPath,
  FilesystemAuthority,
} from "./filesystem-authority.zs";

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
  in path: AuthorizedPath
) => void throws ShellError on thread.main;

internal struct ShellBackend {
  openExternal: ShellOpenExternalOperation;
  operateOnPath: ShellPathOperation;
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
  in path: AuthorizedPath
): void throws ShellError on thread.main {
  throw shellUnavailable(
    operation,
    in target,
    "shell access is unavailable before Application.run()"
  );
}

function inactiveShellBackend(): ShellBackend on thread.main {
  const openExternal: ShellOpenExternalOperation = rejectOpenExternal;
  const operateOnPath: ShellPathOperation = rejectPathOperation;
  return ShellBackend({ openExternal, operateOnPath });
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
  in path: AuthorizedPath
): void throws ShellError on thread.main {
  throw shellUnavailable(
    operation,
    in target,
    "filesystem-backed shell operations are unsupported by the active application platform"
  );
}

internal function unsupportedShellBackend(): ShellBackend on thread.main {
  const openExternal: ShellOpenExternalOperation =
    rejectUnsupportedOpenExternal;
  const operateOnPath: ShellPathOperation = rejectUnsupportedPathOperation;
  return ShellBackend({ openExternal, operateOnPath });
}

class ShellManagerState on thread.main {
  backend: ShellBackend;
  readonly authority: FilesystemAuthority;

  function openExternal(
    in url: String
  ): void throws ShellError {
    try this.backend.openExternal(in url);
  }

  function operateOnPath(
    operation: ShellOperation,
    in path: String
  ): void throws ShellError {
    const authorization = attempt this.authority.authorize(in path);
    const authorized = match (authorization) {
      success(value) => value;
      failure(error) => throw ShellError({
        operation,
        target: copy error.target,
        message: copy error.message,
      });
    };
    try this.backend.operateOnPath(
      operation,
      in path,
      in authorized
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

  internal constructor(authority: FilesystemAuthority) {
    this.state = new ShellManagerState({
      backend: inactiveShellBackend(),
      authority,
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
  authority: FilesystemAuthority
): ShellManager on thread.main {
  return new ShellManager(authority);
}
