import { thread } from "std/thread";

export struct FileFilter {
  name: String;
  extensions: Array<String>;
}

export struct OpenDialogOptions {
  title: String = "";
  defaultPath: String = "";
  filters: Array<FileFilter> = Array<FileFilter>();
}

export struct SaveDialogOptions {
  title: String = "";
  defaultPath: String = "";
  defaultName: String = "";
  filters: Array<FileFilter> = Array<FileFilter>();
}

export enum DialogOperation {
  openFile,
  openFiles,
  openDirectory,
  saveFile,
}

export struct DialogError {
  operation: DialogOperation;
  message: String;
}

internal type OpenFileDialogOperation = (
  in options: OpenDialogOptions
) => Option<String> throws DialogError on thread.main;

internal type OpenFilesDialogOperation = (
  in options: OpenDialogOptions
) => Option<Array<String>> throws DialogError on thread.main;

internal type SaveFileDialogOperation = (
  in options: SaveDialogOptions
) => Option<String> throws DialogError on thread.main;

internal struct DialogBackend {
  openFile: OpenFileDialogOperation;
  openFiles: OpenFilesDialogOperation;
  openDirectory: OpenFileDialogOperation;
  saveFile: SaveFileDialogOperation;
}

function rejectOpenFileDialog(
  in options: OpenDialogOptions
): Option<String> throws DialogError on thread.main {
  throw DialogError({
    operation: DialogOperation.openFile,
    message: "file dialogs are unavailable before Application.run()",
  });
}

function rejectOpenFilesDialog(
  in options: OpenDialogOptions
): Option<Array<String>> throws DialogError on thread.main {
  throw DialogError({
    operation: DialogOperation.openFiles,
    message: "file dialogs are unavailable before Application.run()",
  });
}

function rejectOpenDirectoryDialog(
  in options: OpenDialogOptions
): Option<String> throws DialogError on thread.main {
  throw DialogError({
    operation: DialogOperation.openDirectory,
    message: "file dialogs are unavailable before Application.run()",
  });
}

function rejectSaveFileDialog(
  in options: SaveDialogOptions
): Option<String> throws DialogError on thread.main {
  throw DialogError({
    operation: DialogOperation.saveFile,
    message: "file dialogs are unavailable before Application.run()",
  });
}

function inactiveDialogBackend(): DialogBackend on thread.main {
  const openFile: OpenFileDialogOperation = rejectOpenFileDialog;
  const openFiles: OpenFilesDialogOperation = rejectOpenFilesDialog;
  const openDirectory: OpenFileDialogOperation = rejectOpenDirectoryDialog;
  const saveFile: SaveFileDialogOperation = rejectSaveFileDialog;
  return DialogBackend({
    openFile,
    openFiles,
    openDirectory,
    saveFile,
  });
}

function unsupportedOpenFileDialog(
  in options: OpenDialogOptions
): Option<String> throws DialogError on thread.main {
  throw DialogError({
    operation: DialogOperation.openFile,
    message: "file dialogs are unsupported by the active application platform",
  });
}

function unsupportedOpenFilesDialog(
  in options: OpenDialogOptions
): Option<Array<String>> throws DialogError on thread.main {
  throw DialogError({
    operation: DialogOperation.openFiles,
    message: "file dialogs are unsupported by the active application platform",
  });
}

function unsupportedOpenDirectoryDialog(
  in options: OpenDialogOptions
): Option<String> throws DialogError on thread.main {
  throw DialogError({
    operation: DialogOperation.openDirectory,
    message: "file dialogs are unsupported by the active application platform",
  });
}

function unsupportedSaveFileDialog(
  in options: SaveDialogOptions
): Option<String> throws DialogError on thread.main {
  throw DialogError({
    operation: DialogOperation.saveFile,
    message: "file dialogs are unsupported by the active application platform",
  });
}

internal function unsupportedDialogBackend(): DialogBackend on thread.main {
  const openFile: OpenFileDialogOperation = unsupportedOpenFileDialog;
  const openFiles: OpenFilesDialogOperation = unsupportedOpenFilesDialog;
  const openDirectory: OpenFileDialogOperation = unsupportedOpenDirectoryDialog;
  const saveFile: SaveFileDialogOperation = unsupportedSaveFileDialog;
  return DialogBackend({
    openFile,
    openFiles,
    openDirectory,
    saveFile,
  });
}

class DialogManagerState on thread.main {
  backend: DialogBackend;

  function openFile(
    in options: OpenDialogOptions
  ): Option<String> throws DialogError on thread.main {
    return try this.backend.openFile(in options);
  }

  function openFiles(
    in options: OpenDialogOptions
  ): Option<Array<String>> throws DialogError on thread.main {
    return try this.backend.openFiles(in options);
  }

  function openDirectory(
    in options: OpenDialogOptions
  ): Option<String> throws DialogError on thread.main {
    return try this.backend.openDirectory(in options);
  }

  function saveFile(
    in options: SaveDialogOptions
  ): Option<String> throws DialogError on thread.main {
    return try this.backend.saveFile(in options);
  }

  function start(inout this, backend: DialogBackend): void {
    this.backend = backend;
  }

  function stop(inout this): void {
    this.backend = inactiveDialogBackend();
  }
}

export readonly class DialogManager on thread.main {
  internal readonly state: DialogManagerState;

  internal constructor() {
    this.state = new DialogManagerState({ backend: inactiveDialogBackend() });
  }

  async function openFile(
    in options: OpenDialogOptions
  ): Option<String> throws DialogError on thread.main {
    return try this.state.openFile(in options);
  }

  async function openFiles(
    in options: OpenDialogOptions
  ): Option<Array<String>> throws DialogError on thread.main {
    return try this.state.openFiles(in options);
  }

  async function openDirectory(
    in options: OpenDialogOptions
  ): Option<String> throws DialogError on thread.main {
    return try this.state.openDirectory(in options);
  }

  async function saveFile(
    in options: SaveDialogOptions
  ): Option<String> throws DialogError on thread.main {
    return try this.state.saveFile(in options);
  }

  internal function start(
    inout this,
    backend: DialogBackend
  ): void on thread.main {
    this.state.start(backend);
  }

  internal function stop(inout this): void on thread.main {
    this.state.stop();
  }
}

internal function createDialogManager(): DialogManager on thread.main {
  return new DialogManager();
}
