import { thread } from "std/thread";
import { ApplicationPaths } from "../../api/zapp/service.zs";
import {
  FilesystemAuthorityBackend,
  FilesystemAuthorityError,
  createFilesystemAuthority,
} from "../../framework/filesystem-authority.zs";

function canonicalPath(
  in source: String,
  in paths: ApplicationPaths
): Option<String> throws FilesystemAuthorityError on thread.main {
  return Option.some(copy source);
}

function containsPath(
  in path: String,
  in root: String
): boolean on thread.main {
  if (path == root) return true;
  return root == "/selected/folder" && path == "/selected/folder/child.txt";
}

function main(): i32 on thread.main {
  const paths = ApplicationPaths({
    executable: "/app/zapp",
    resources: "/app/resources",
    data: "/app/data",
    config: "/app/config",
    cache: "/app/cache",
  });
  let authority = createFilesystemAuthority(in paths);
  authority.start(FilesystemAuthorityBackend({
    canonicalize: canonicalPath,
    contains: containsPath,
  }));

  const deniedBeforeGrant = attempt authority.authorize("/selected/report.txt");
  match (deniedBeforeGrant) {
    success(_) => return 1;
    failure(_) => {}
  }

  const fileGrant = attempt authority.grantFile("/selected/report.txt");
  match (fileGrant) {
    success => {}
    failure(_) => return 2;
  }
  const exactFile = attempt authority.authorize("/selected/report.txt");
  match (exactFile) {
    success(path) => {
      if (path.resolved != "/selected/report.txt") return 3;
    }
    failure(_) => return 4;
  }

  const fileDescendant = attempt authority.authorize(
    "/selected/report.txt/child"
  );
  match (fileDescendant) {
    success(_) => return 5;
    failure(_) => {}
  }

  const directoryGrant = attempt authority.grantDirectory("/selected/folder");
  match (directoryGrant) {
    success => {}
    failure(_) => return 6;
  }
  const directoryChild = attempt authority.authorize(
    "/selected/folder/child.txt"
  );
  match (directoryChild) {
    success(path) => {
      if (path.resolved != "/selected/folder/child.txt") return 7;
    }
    failure(_) => return 8;
  }

  authority.stop();
  authority.start(FilesystemAuthorityBackend({
    canonicalize: canonicalPath,
    contains: containsPath,
  }));
  const deniedAfterRestart = attempt authority.authorize(
    "/selected/report.txt"
  );
  match (deniedAfterRestart) {
    success(_) => return 9;
    failure(_) => {}
  }
  return 0;
}
