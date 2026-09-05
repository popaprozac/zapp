import AppKit from "AppKit/AppKit.h";
import Foundation from "Foundation/Foundation.h";
import { thread } from "std/thread";
import {
  ShellBackend,
  ShellError,
  ShellOpenExternalOperation,
  ShellOperation,
} from "../../shell.zs";
import { macOSApplicationSmokeMode } from "./application-host.zs";

function openMacOSExternalURL(
  in address: String
): void throws ShellError on thread.main {
  const url = Foundation.NSURL.URLWithString(copy address);
  if (url == null) {
    throw ShellError({
      operation: ShellOperation.openExternal,
      url: copy address,
      message: `invalid external URL "${address}"`,
    });
  }
  // Smoke tests exercise the complete policy and bridge route without
  // launching the user's default browser as a test side effect.
  if (macOSApplicationSmokeMode()) return;
  if (!AppKit.NSWorkspace.sharedWorkspace.openURL(url)) {
    throw ShellError({
      operation: ShellOperation.openExternal,
      url: copy address,
      message: `the operating system could not open "${address}"`,
    });
  }
}

internal function macOSShellBackend(): ShellBackend on thread.main {
  const openExternal: ShellOpenExternalOperation = openMacOSExternalURL;
  return ShellBackend({ openExternal });
}
