import { thread } from "std/thread";

export enum ClipboardOperation {
  readText,
  writeText,
  clear,
}

export struct ClipboardError {
  operation: ClipboardOperation;
  message: String;
}

internal type ClipboardReadTextOperation = (
) => Option<String> throws ClipboardError on thread.main;

internal type ClipboardWriteTextOperation = (
  in text: String
) => void throws ClipboardError on thread.main;

internal type ClipboardClearOperation = (
) => void throws ClipboardError on thread.main;

internal struct ClipboardBackend {
  readText: ClipboardReadTextOperation;
  writeText: ClipboardWriteTextOperation;
  clear: ClipboardClearOperation;
}

function clipboardUnavailable(
  operation: ClipboardOperation,
  message: String
): ClipboardError {
  return ClipboardError({ operation, message: move message });
}

function rejectClipboardReadText(
): Option<String> throws ClipboardError on thread.main {
  throw clipboardUnavailable(
    ClipboardOperation.readText,
    "clipboard access is unavailable before Application.run()"
  );
}

function rejectClipboardWriteText(
  in text: String
): void throws ClipboardError on thread.main {
  throw clipboardUnavailable(
    ClipboardOperation.writeText,
    "clipboard access is unavailable before Application.run()"
  );
}

function rejectClipboardClear(
): void throws ClipboardError on thread.main {
  throw clipboardUnavailable(
    ClipboardOperation.clear,
    "clipboard access is unavailable before Application.run()"
  );
}

function inactiveClipboardBackend(): ClipboardBackend on thread.main {
  const readText: ClipboardReadTextOperation = rejectClipboardReadText;
  const writeText: ClipboardWriteTextOperation = rejectClipboardWriteText;
  const clear: ClipboardClearOperation = rejectClipboardClear;
  return ClipboardBackend({ readText, writeText, clear });
}

function rejectUnsupportedClipboardReadText(
): Option<String> throws ClipboardError on thread.main {
  throw clipboardUnavailable(
    ClipboardOperation.readText,
    "clipboard access is unsupported by the active application platform"
  );
}

function rejectUnsupportedClipboardWriteText(
  in text: String
): void throws ClipboardError on thread.main {
  throw clipboardUnavailable(
    ClipboardOperation.writeText,
    "clipboard access is unsupported by the active application platform"
  );
}

function rejectUnsupportedClipboardClear(
): void throws ClipboardError on thread.main {
  throw clipboardUnavailable(
    ClipboardOperation.clear,
    "clipboard access is unsupported by the active application platform"
  );
}

internal function unsupportedClipboardBackend(
): ClipboardBackend on thread.main {
  const readText: ClipboardReadTextOperation = rejectUnsupportedClipboardReadText;
  const writeText: ClipboardWriteTextOperation = rejectUnsupportedClipboardWriteText;
  const clear: ClipboardClearOperation = rejectUnsupportedClipboardClear;
  return ClipboardBackend({ readText, writeText, clear });
}

class ClipboardManagerState on thread.main {
  backend: ClipboardBackend;

  function readText(
  ): Option<String> throws ClipboardError {
    return try this.backend.readText();
  }

  function writeText(
    in text: String
  ): void throws ClipboardError {
    try this.backend.writeText(in text);
  }

  function clear(): void throws ClipboardError {
    try this.backend.clear();
  }

  function start(inout this, backend: ClipboardBackend): void {
    this.backend = backend;
  }

  function stop(inout this): void {
    this.backend = inactiveClipboardBackend();
  }
}

export readonly class ClipboardManager on thread.main {
  internal readonly state: ClipboardManagerState;

  internal constructor() {
    this.state = new ClipboardManagerState({
      backend: inactiveClipboardBackend(),
    });
  }

  function readText(
  ): Option<String> throws ClipboardError on thread.main {
    return try this.state.readText();
  }

  function writeText(
    in text: String
  ): void throws ClipboardError on thread.main {
    try this.state.writeText(in text);
  }

  function clear(): void throws ClipboardError on thread.main {
    try this.state.clear();
  }

  internal function start(
    inout this,
    backend: ClipboardBackend
  ): void on thread.main {
    this.state.start(backend);
  }

  internal function stop(inout this): void on thread.main {
    this.state.stop();
  }
}

internal function createClipboardManager(
): ClipboardManager on thread.main {
  return new ClipboardManager();
}
