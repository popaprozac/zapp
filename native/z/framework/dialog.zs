import { thread } from "std/thread";
import {
  FilesystemAuthority,
} from "./filesystem-authority.zs";

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
  authority: FilesystemAuthority;

  function grantFile(
    inout this,
    in path: String,
    operation: DialogOperation
  ): void throws DialogError {
    const granted = attempt this.authority.grantFile(in path);
    match (granted) {
      success => {}
      failure(error) => throw DialogError({
        operation,
        message: copy error.message,
      });
    }
  }

  function grantDirectory(
    inout this,
    in path: String
  ): void throws DialogError {
    const granted = attempt this.authority.grantDirectory(in path);
    match (granted) {
      success => {}
      failure(error) => throw DialogError({
        operation: DialogOperation.openDirectory,
        message: copy error.message,
      });
    }
  }

  function openFile(
    inout this,
    in options: OpenDialogOptions
  ): Option<String> throws DialogError on thread.main {
    const selected = try this.backend.openFile(in options);
    return match (selected) {
      some(path) => {
        try this.grantFile(in path, DialogOperation.openFile);
        select Option.some(move path);
      }
      none => Option.none;
    };
  }

  function openFiles(
    inout this,
    in options: OpenDialogOptions
  ): Option<Array<String>> throws DialogError on thread.main {
    const selected = try this.backend.openFiles(in options);
    return match (selected) {
      some(paths) => {
        for (const path of paths) {
          try this.grantFile(in path, DialogOperation.openFiles);
        }
        select Option.some(move paths);
      }
      none => Option.none;
    };
  }

  function openDirectory(
    inout this,
    in options: OpenDialogOptions
  ): Option<String> throws DialogError on thread.main {
    const selected = try this.backend.openDirectory(in options);
    return match (selected) {
      some(path) => {
        try this.grantDirectory(in path);
        select Option.some(move path);
      }
      none => Option.none;
    };
  }

  function saveFile(
    inout this,
    in options: SaveDialogOptions
  ): Option<String> throws DialogError on thread.main {
    const selected = try this.backend.saveFile(in options);
    return match (selected) {
      some(path) => {
        try this.grantFile(in path, DialogOperation.saveFile);
        select Option.some(move path);
      }
      none => Option.none;
    };
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

  internal constructor(authority: FilesystemAuthority) {
    this.state = new DialogManagerState({
      backend: inactiveDialogBackend(),
      authority,
    });
  }

  async function openFile(
    in options: OpenDialogOptions
  ): Option<String> throws DialogError on thread.main {
    let state = this.state;
    return try state.openFile(in options);
  }

  async function openFiles(
    in options: OpenDialogOptions
  ): Option<Array<String>> throws DialogError on thread.main {
    let state = this.state;
    return try state.openFiles(in options);
  }

  async function openDirectory(
    in options: OpenDialogOptions
  ): Option<String> throws DialogError on thread.main {
    let state = this.state;
    return try state.openDirectory(in options);
  }

  async function saveFile(
    in options: SaveDialogOptions
  ): Option<String> throws DialogError on thread.main {
    let state = this.state;
    return try state.saveFile(in options);
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

internal function createDialogManager(
  authority: FilesystemAuthority
): DialogManager on thread.main {
  return new DialogManager(authority);
}
