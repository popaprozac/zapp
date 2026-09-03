import Foundation from "Foundation/Foundation.h";
import { ApplicationMetadata } from "../../application-metadata.zs";
import {
  ApplicationContext,
  ApplicationPaths,
} from "../../../api/zapp/service.zs";
import process from "std/process";
import { thread } from "std/thread";

function macOSExecutablePath(
): Foundation.NSString on thread.main = raw objc {
  NSString *path = [[NSBundle mainBundle] executablePath];
  if (path == nil) path = [[[NSProcessInfo processInfo] arguments] firstObject];
  return path != nil ? path : @"";
}

function macOSResourcePath(
): Foundation.NSString on thread.main = raw objc {
  NSString *path = [[NSBundle mainBundle] resourcePath];
  if (path == nil) {
    path = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
  }
  return path != nil ? path : @"";
}

function macOSApplicationDirectory(
  in identifier: Foundation.NSString,
  kind: i32
): Foundation.NSString on thread.main = raw objc {
  NSSearchPathDirectory directory = kind == 2
    ? NSCachesDirectory
    : NSApplicationSupportDirectory;
  NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(
    directory,
    NSUserDomainMask,
    YES
  );
  NSString *base = [paths firstObject];
  if (base == nil) base = NSTemporaryDirectory();
  NSString *path = [base stringByAppendingPathComponent:identifier];
  if (kind == 1) path = [path stringByAppendingPathComponent:@"Config"];
  return path;
}

export function createMacOSApplicationContext(
  in metadata: ApplicationMetadata
): ApplicationContext on thread.main {
  const identifier: Foundation.NSString = copy metadata.identifier;
  const executable: String = macOSExecutablePath();
  const resources: String = macOSResourcePath();
  const data: String = macOSApplicationDirectory(in identifier, 0);
  const config: String = macOSApplicationDirectory(in identifier, 1);
  const cache: String = macOSApplicationDirectory(in identifier, 2);
  const arguments = process.args();
  return ApplicationContext({
    metadata: ApplicationMetadata({
      name: copy metadata.name,
      identifier: copy metadata.identifier,
      version: copy metadata.version,
    }),
    arguments: arguments.freeze(),
    paths: ApplicationPaths({
      executable: move executable,
      resources: move resources,
      data: move data,
      config: move config,
      cache: move cache,
    }),
  });
}
