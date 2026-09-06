import fs from "std/fs";
import { thread } from "std/thread";
import {
  FilesystemAuthority,
  FilesystemAuthorityError,
} from "./filesystem-authority.zs";

export enum FileOperation {
  readText,
  writeText,
}

export struct FileError {
  operation: FileOperation;
  path: String;
  message: String;
}

function authorizationError(
  operation: FileOperation,
  error: FilesystemAuthorityError
): FileError {
  return FileError({
    operation,
    path: copy error.target,
    message: copy error.message,
  });
}

// Zapp owns path authority and focused framework errors. std/fs remains the
// portable implementation of the actual file operation. Moving only owned
// String snapshots into the worker keeps blocking I/O off thread.main.
export readonly class FileManager on thread.main {
  internal readonly authority: FilesystemAuthority;

  internal constructor(authority: FilesystemAuthority) {
    this.authority = authority;
  }

  async function readText(
    in path: String
  ): String throws FileError on thread.main {
    const authorization = attempt this.authority.authorize(in path);
    const authorized = match (authorization) {
      success(value) => value;
      failure(error) => throw authorizationError(
        FileOperation.readText,
        move error
      );
    };
    const resolved = copy authorized.resolved;
    const worker = thread.spawn(move (): String throws String => {
      return try fs.readText(resolved);
    });
    const read = attempt await worker;
    return match (read) {
      success(value) => value;
      failure(message) => throw FileError({
        operation: FileOperation.readText,
        path: copy path,
        message,
      });
    };
  }

  async function writeText(
    in path: String,
    in contents: String
  ): void throws FileError on thread.main {
    const authorization = attempt this.authority.authorize(in path);
    const authorized = match (authorization) {
      success(value) => value;
      failure(error) => throw authorizationError(
        FileOperation.writeText,
        move error
      );
    };
    const resolved = copy authorized.resolved;
    const source = copy contents;
    const worker = thread.spawn(move (): void throws String => {
      try fs.writeText(resolved, source);
    });
    const written = attempt await worker;
    match (written) {
      success => return;
      failure(message) => throw FileError({
        operation: FileOperation.writeText,
        path: copy path,
        message,
      });
    }
  }
}

internal function createFileManager(
  authority: FilesystemAuthority
): FileManager on thread.main {
  return new FileManager(authority);
}
