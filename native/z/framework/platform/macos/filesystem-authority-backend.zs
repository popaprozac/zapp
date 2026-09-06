import Foundation from "Foundation/Foundation.h";
import { thread } from "std/thread";
import { ApplicationPaths } from "../../../api/zapp/service.zs";
import {
  FilesystemAuthorityBackend,
  FilesystemAuthorityError,
  FilesystemCanonicalizeOperation,
  FilesystemContainsOperation,
} from "../../filesystem-authority.zs";

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

function canonicalizeMacOSFilesystemPath(
  in source: String,
  in paths: ApplicationPaths
): Option<String> throws FilesystemAuthorityError on thread.main {
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

function containsMacOSFilesystemPath(
  in path: String,
  in root: String
): boolean on thread.main {
  const nativePath: Foundation.NSString = copy path;
  const nativeRoot: Foundation.NSString = copy root;
  return macOSFilesystemPathIsWithin(in nativePath, in nativeRoot);
}

internal function macOSFilesystemAuthorityBackend(
): FilesystemAuthorityBackend on thread.main {
  const canonicalize: FilesystemCanonicalizeOperation =
    canonicalizeMacOSFilesystemPath;
  const contains: FilesystemContainsOperation = containsMacOSFilesystemPath;
  return FilesystemAuthorityBackend({ canonicalize, contains });
}
