import AppKit from "AppKit/AppKit.h";
import Foundation from "Foundation/Foundation.h";
import UniformTypeIdentifiers from "UniformTypeIdentifiers/UniformTypeIdentifiers.h";
import {
  DialogBackend,
  DialogError,
  DialogOperation,
  FileFilter,
  OpenDialogOptions,
  OpenFileDialogOperation,
  OpenFilesDialogOperation,
  SaveDialogOptions,
  SaveFileDialogOperation,
} from "../../dialog.zs";
import { thread } from "std/thread";

function applyPanelOptions(
  in panel: AppKit.NSSavePanel,
  in title: String,
  in defaultPath: String,
  in filters: Array<FileFilter>
): void on thread.main {
  if (title.byteLength > 0) panel.title = title;
  if (defaultPath.byteLength > 0) {
    panel.directoryURL = Foundation.NSURL.fileURLWithPath(copy defaultPath);
  }
  if (filters.length == 0) return;
  const contentTypes = Foundation.NSMutableArray.array();
  for (const filter of filters) {
    for (const extension of filter.extensions) {
      const contentType =
        UniformTypeIdentifiers.UTType.typeWithFilenameExtension(extension);
      if (contentType != null) contentTypes.addObject(contentType);
    }
  }
  if (contentTypes.count > 0) panel.allowedContentTypes = contentTypes;
}

function selectedPanelPath(
  in panel: AppKit.NSSavePanel,
  operation: DialogOperation
): Option<String> throws DialogError on thread.main {
  const url = panel.URL;
  if (url == null) {
    throw DialogError({
      operation,
      message: "the native file dialog completed without a selected URL",
    });
  }
  const nativePath = url.path;
  if (nativePath == null) {
    throw DialogError({
      operation,
      message: "the selected native URL does not have a filesystem path",
    });
  }
  const path: String = nativePath;
  return Option.some(move path);
}

function openMacOSFile(
  in options: OpenDialogOptions
): Option<String> throws DialogError on thread.main {
  const panel = AppKit.NSOpenPanel.openPanel();
  applyPanelOptions(
    panel,
    in options.title,
    in options.defaultPath,
    in options.filters
  );
  panel.allowsMultipleSelection = false;
  panel.canChooseDirectories = false;
  panel.canChooseFiles = true;
  if (panel.runModal() != AppKit.NSModalResponseOK) return Option.none;
  return try selectedPanelPath(panel, DialogOperation.openFile);
}

function openMacOSFiles(
  in options: OpenDialogOptions
): Option<Array<String>> throws DialogError on thread.main {
  const panel = AppKit.NSOpenPanel.openPanel();
  applyPanelOptions(
    panel,
    in options.title,
    in options.defaultPath,
    in options.filters
  );
  panel.allowsMultipleSelection = true;
  panel.canChooseDirectories = false;
  panel.canChooseFiles = true;
  if (panel.runModal() != AppKit.NSModalResponseOK) return Option.none;

  const urls = panel.URLs;
  let paths = Array<String>();
  let index: usize = 0;
  while (index < usize(urls.count)) {
    const value = urls.objectAtIndex(index);
    if (value instanceof Foundation.NSURL) {
      const nativePath = value.path;
      if (nativePath != null) {
        const path: String = nativePath;
        paths.push(move path);
      }
    }
    index = index + 1;
  }
  if (paths.length == 0) {
    throw DialogError({
      operation: DialogOperation.openFiles,
      message: "the native file dialog completed without selected filesystem paths",
    });
  }
  return Option.some(move paths);
}

function openMacOSDirectory(
  in options: OpenDialogOptions
): Option<String> throws DialogError on thread.main {
  const panel = AppKit.NSOpenPanel.openPanel();
  applyPanelOptions(
    panel,
    in options.title,
    in options.defaultPath,
    in options.filters
  );
  panel.allowsMultipleSelection = false;
  panel.canChooseDirectories = true;
  panel.canChooseFiles = false;
  if (panel.runModal() != AppKit.NSModalResponseOK) return Option.none;
  return try selectedPanelPath(panel, DialogOperation.openDirectory);
}

function saveMacOSFile(
  in options: SaveDialogOptions
): Option<String> throws DialogError on thread.main {
  const panel = AppKit.NSSavePanel.savePanel();
  applyPanelOptions(
    panel,
    in options.title,
    in options.defaultPath,
    in options.filters
  );
  if (options.defaultName.byteLength > 0) {
    panel.nameFieldStringValue = options.defaultName;
  }
  if (panel.runModal() != AppKit.NSModalResponseOK) return Option.none;
  return try selectedPanelPath(panel, DialogOperation.saveFile);
}

internal function macOSDialogBackend(): DialogBackend on thread.main {
  const openFile: OpenFileDialogOperation = openMacOSFile;
  const openFiles: OpenFilesDialogOperation = openMacOSFiles;
  const openDirectory: OpenFileDialogOperation = openMacOSDirectory;
  const saveFile: SaveFileDialogOperation = saveMacOSFile;
  return DialogBackend({
    openFile,
    openFiles,
    openDirectory,
    saveFile,
  });
}
