import AppKit from "AppKit/AppKit.h";
import Foundation from "Foundation/Foundation.h";
import { thread } from "std/thread";
import { ApplicationPaths } from "../../../api/zapp/service.zs";
import {
  ShellBackend,
  ShellAuthorizePathOperation,
  ShellError,
  ShellOpenExternalOperation,
  ShellOperation,
  ShellPathOperation,
} from "../../shell.zs";
import { configuredFilesystemAllowAtIndex } from "./configured-webview.zs";
import { macOSApplicationSmokeMode } from "./application-host.zs";

function normalizeMacOSFilesystemPath(
  in source: Foundation.NSString,
  in dataPath: Foundation.NSString,
  in configPath: Foundation.NSString,
  in cachePath: Foundation.NSString,
  in resourcesPath: Foundation.NSString
): Foundation.NSString | null on thread.main = raw objc {
  if (source == nil || source.length == 0) return nil;
  NSString *expanded = source;
  if ([source isEqualToString:@"~"] || [source hasPrefix:@"~/"]) {
    expanded = [source stringByExpandingTildeInPath];
  } else if ([source hasPrefix:@"$"]) {
    NSRange slash = [source rangeOfString:@"/"];
    NSString *name = slash.location == NSNotFound
      ? [source substringFromIndex:1]
      : [source substringWithRange:NSMakeRange(1, slash.location - 1)];
    NSString *suffix = slash.location == NSNotFound
      ? @""
      : [source substringFromIndex:slash.location];
    NSString *root = nil;
    if ([name isEqualToString:@"userData"] || [name isEqualToString:@"appData"]) {
      root = dataPath;
    } else if ([name isEqualToString:@"config"]) {
      root = configPath;
    } else if ([name isEqualToString:@"cache"]) {
      root = cachePath;
    } else if ([name isEqualToString:@"resources"]) {
      root = resourcesPath;
    } else if ([name isEqualToString:@"home"]) {
      root = NSHomeDirectory();
    } else if ([name isEqualToString:@"temp"]) {
      root = NSTemporaryDirectory();
    } else if ([name isEqualToString:@"documents"] || [name isEqualToString:@"downloads"]) {
      NSSearchPathDirectory directory = [name isEqualToString:@"downloads"]
        ? NSDownloadsDirectory
        : NSDocumentDirectory;
      root = [NSSearchPathForDirectoriesInDomains(
        directory,
        NSUserDomainMask,
        YES
      ) firstObject];
    }
    if (root == nil || root.length == 0) return nil;
    expanded = [root stringByAppendingString:suffix];
  }
  if (![expanded isAbsolutePath]) return nil;
  return [[expanded stringByStandardizingPath] stringByResolvingSymlinksInPath];
}

function macOSFilesystemPathExists(
  in path: Foundation.NSString
): boolean on thread.main = raw objc {
  return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

function macOSFilesystemPathIsWithin(
  in path: Foundation.NSString,
  in root: Foundation.NSString
): boolean on thread.main = raw objc {
  if ([path isEqualToString:root]) return true;
  NSString *prefix = [root hasSuffix:@"/"]
    ? root
    : [root stringByAppendingString:@"/"];
  return [path hasPrefix:prefix];
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

function resolvedMacOSFilesystemPath(
  in source: String,
  in paths: ApplicationPaths
): Option<String> on thread.main {
  const nativeSource: Foundation.NSString = copy source;
  const dataPath: Foundation.NSString = copy paths.data;
  const configPath: Foundation.NSString = copy paths.config;
  const cachePath: Foundation.NSString = copy paths.cache;
  const resourcesPath: Foundation.NSString = copy paths.resources;
  const resolved = normalizeMacOSFilesystemPath(
    in nativeSource,
    in dataPath,
    in configPath,
    in cachePath,
    in resourcesPath
  );
  if (resolved == null) return Option<String>.none;
  const path: String = resolved;
  return Option.some(move path);
}

function authorizeMacOSFilesystemPath(
  operation: ShellOperation,
  in source: String,
  in paths: ApplicationPaths
): String throws ShellError on thread.main {
  const resolved = resolvedMacOSFilesystemPath(in source, in paths);
  const path = match (resolved) {
    some(value) => value;
    none => throw ShellError({
      operation,
      target: copy source,
      message: `invalid filesystem path "${source}"`,
    });
  };
  let index: usize = 0;
  while (true) {
    const configured = configuredFilesystemAllowAtIndex(index);
    const rootSource = match (configured) {
      some(value) => value;
      none => throw ShellError({
        operation,
        target: copy source,
        message: `filesystem path "${source}" is outside the authority declared by security.filesystem.allow`,
      });
    };
    const resolvedRoot = resolvedMacOSFilesystemPath(in rootSource, in paths);
    match (resolvedRoot) {
      some(root) => {
        const nativePath: Foundation.NSString = copy path;
        const nativeRoot: Foundation.NSString = copy root;
        if (macOSFilesystemPathIsWithin(in nativePath, in nativeRoot)) {
          return path;
        }
      }
      none => {}
    }
    index = index + 1;
  }
  throw ShellError({
    operation,
    target: copy source,
    message: `filesystem path "${source}" is outside the authority declared by security.filesystem.allow`,
  });
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
  in resolvedPath: String
): void throws ShellError on thread.main {
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
  const authorizePath: ShellAuthorizePathOperation =
    authorizeMacOSFilesystemPath;
  return ShellBackend({ openExternal, operateOnPath, authorizePath });
}
