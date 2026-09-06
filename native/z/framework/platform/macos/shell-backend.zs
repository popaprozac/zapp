import AppKit from "AppKit/AppKit.h";
import Foundation from "Foundation/Foundation.h";
import { thread } from "std/thread";
import { AuthorizedPath } from "../../filesystem-authority.zs";
import {
  ShellBackend,
  ShellError,
  ShellOpenExternalOperation,
  ShellOperation,
  ShellPathOperation,
} from "../../shell.zs";
import { macOSApplicationSmokeMode } from "./application-host.zs";

function macOSFilesystemPathExists(
  in path: Foundation.NSString
): boolean on thread.main = raw objc {
  return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

function revealMacOSFilesystemURL(
  in url: Foundation.NSURL
): void on thread.main = raw objc {
  [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
}

function trashMacOSFilesystemURL(
  in url: Foundation.NSURL
): boolean on thread.main = raw objc {
  NSError *error = nil;
  return [[NSFileManager defaultManager]
    trashItemAtURL:url
    resultingItemURL:nil
    error:&error];
}

function openMacOSExternalURL(
  in address: String
): void throws ShellError on thread.main {
  const url = Foundation.NSURL.URLWithString(copy address);
  if (url == null) {
    throw ShellError({
      operation: ShellOperation.openExternal,
      target: copy address,
      message: `invalid external URL "${address}"`,
    });
  }
  // Smoke tests exercise the complete policy and bridge route without
  // launching the user's default browser as a test side effect.
  if (macOSApplicationSmokeMode()) return;
  if (!AppKit.NSWorkspace.sharedWorkspace.openURL(url)) {
    throw ShellError({
      operation: ShellOperation.openExternal,
      target: copy address,
      message: `the operating system could not open "${address}"`,
    });
  }
}

function operateOnMacOSFilesystemPath(
  operation: ShellOperation,
  in target: String,
  in path: AuthorizedPath
): void throws ShellError on thread.main {
  const resolvedPath = copy path.resolved;
  const nativePath: Foundation.NSString = copy resolvedPath;
  if (!macOSFilesystemPathExists(in nativePath)) {
    throw ShellError({
      operation,
      target: copy target,
      message: `filesystem path "${target}" does not exist`,
    });
  }
  // Smoke tests prove validation, authorization, routing, and typed errors
  // without opening Finder, launching another application, or moving files.
  if (macOSApplicationSmokeMode()) return;
  const url = Foundation.NSURL.fileURLWithPath(copy resolvedPath);
  match (operation) {
    openPath => {
      if (!AppKit.NSWorkspace.sharedWorkspace.openURL(url)) {
        throw ShellError({
          operation,
          target: copy target,
          message: `the operating system could not open "${target}"`,
        });
      }
    }
    reveal => revealMacOSFilesystemURL(in url);
    trash => {
      if (!trashMacOSFilesystemURL(in url)) {
        throw ShellError({
          operation,
          target: copy target,
          message: `the operating system could not move "${target}" to Trash`,
        });
      }
    }
    openExternal => throw ShellError({
      operation,
      target: copy target,
      message: "an external URL cannot be handled as a filesystem path",
    });
  }
}

internal function macOSShellBackend(): ShellBackend on thread.main {
  const openExternal: ShellOpenExternalOperation = openMacOSExternalURL;
  const operateOnPath: ShellPathOperation = operateOnMacOSFilesystemPath;
  return ShellBackend({ openExternal, operateOnPath });
}
