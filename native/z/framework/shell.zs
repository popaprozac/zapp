import { thread } from "std/thread";

export enum ShellOperation {
  openExternal,
}

export struct ShellError {
  operation: ShellOperation;
  url: String;
  message: String;
}

internal type ShellOpenExternalOperation = (
  in url: String
) => void throws ShellError on thread.main;

internal struct ShellBackend {
  openExternal: ShellOpenExternalOperation;
}

function shellUnavailable(
  operation: ShellOperation,
  in url: String,
  message: String
): ShellError {
  return ShellError({
    operation,
    url: copy url,
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

function inactiveShellBackend(): ShellBackend on thread.main {
  const openExternal: ShellOpenExternalOperation = rejectOpenExternal;
  return ShellBackend({ openExternal });
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

internal function unsupportedShellBackend(): ShellBackend on thread.main {
  const openExternal: ShellOpenExternalOperation =
    rejectUnsupportedOpenExternal;
  return ShellBackend({ openExternal });
}

class ShellManagerState on thread.main {
  backend: ShellBackend;

  function openExternal(
    in url: String
  ): void throws ShellError {
    try this.backend.openExternal(in url);
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

  internal constructor() {
    this.state = new ShellManagerState({ backend: inactiveShellBackend() });
  }

  function openExternal(
    in url: String
  ): void throws ShellError on thread.main {
    try this.state.openExternal(in url);
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

internal function createShellManager(): ShellManager on thread.main {
  return new ShellManager();
}
