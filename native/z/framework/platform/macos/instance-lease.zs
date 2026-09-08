import Foundation from "Foundation/Foundation.h";
import files from "sys/file.h";
import status from "sys/stat.h";
import descriptors from "fcntl.h";
import system from "unistd.h";
import errors from "errno.h";
import limits from "limits.h";
import digest from "CommonCrypto/CommonDigest.h";

// The kernel-held lease is separate from the eventual launch transport. Never
// unlink the lock file: competing open descriptors must refer to one inode.
// No PID file, polling thread, or stale-file takeover heuristic is involved.
internal readonly struct MacOSInstanceLeaseError {
  code: i32;
  message: String;
}

// The raw boundary owns only descriptor setup and OS error translation. The
// returned Foundation owner is private to the move-only Z lease below.
function acquireInstanceFile(
  in identifier: Foundation.NSString,
  inout errorCode: i32
): Foundation.NSFileHandle | null = raw objc {
  *errorCode = 0;
  char directory[PATH_MAX];
  size_t length = confstr(_CS_DARWIN_USER_TEMP_DIR, directory, sizeof(directory));
  if (length == 0 || length > sizeof(directory)) {
    *errorCode = length > sizeof(directory) ? ENAMETOOLONG : EIO;
    return nil;
  }
  // Do not honor TMPDIR: ask the OS for this user's private temporary root.
  int root = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (root < 0) { *errorCode = errno; return nil; }
  struct stat rootInfo;
  if (fstat(root, &rootInfo) != 0 || !S_ISDIR(rootInfo.st_mode)
      || rootInfo.st_uid != geteuid() || (rootInfo.st_mode & 077) != 0) {
    *errorCode = EPERM;
    close(root);
    return nil;
  }
  const char *subdirectory = "zapp-instance-v1";
  if (mkdirat(root, subdirectory, 0700) != 0 && errno != EEXIST) {
    *errorCode = errno;
    close(root);
    return nil;
  }
  int parent = openat(root, subdirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  int openError = errno;
  close(root);
  if (parent < 0) { *errorCode = openError; return nil; }
  struct stat parentInfo;
  if (fstat(parent, &parentInfo) != 0 || !S_ISDIR(parentInfo.st_mode)
      || parentInfo.st_uid != geteuid() || (parentInfo.st_mode & 077) != 0) {
    *errorCode = EPERM;
    close(parent);
    return nil;
  }
  // Filename encoding must not impose a new application-identifier grammar.
  // Hash exact UTF-8 bytes, not NSString's randomized hash or path components.
  NSData *identity = [identifier dataUsingEncoding:NSUTF8StringEncoding];
  if (identity == nil || identity.length > UINT32_MAX) {
    *errorCode = identity == nil ? EINVAL : ENAMETOOLONG;
    close(parent);
    return nil;
  }
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(identity.bytes, (CC_LONG)identity.length, digest);
  char fileName[CC_SHA256_DIGEST_LENGTH * 2 + sizeof(".lock")];
  const char *hex = "0123456789abcdef";
  for (size_t index = 0; index < sizeof(digest); index++) {
    fileName[index * 2] = hex[digest[index] >> 4];
    fileName[index * 2 + 1] = hex[digest[index] & 15];
  }
  memcpy(fileName + sizeof(digest) * 2, ".lock", sizeof(".lock"));
  int fd = openat(parent, fileName,
    O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600);
  openError = errno;
  close(parent);
  if (fd < 0) { *errorCode = openError; return nil; }
  struct stat fileInfo;
  if (fstat(fd, &fileInfo) != 0 || !S_ISREG(fileInfo.st_mode)
      || fileInfo.st_uid != geteuid() || fileInfo.st_nlink != 1
      || (fileInfo.st_mode & 077) != 0) {
    *errorCode = EPERM;
    close(fd);
    return nil;
  }
  if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
    int lockError = errno;
    close(fd);
    if (lockError != EWOULDBLOCK) *errorCode = lockError;
    return nil;
  }
  NSFileHandle *owner = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
  if (owner == nil) { close(fd); *errorCode = ENOMEM; }
  return owner;
}

function closeInstanceFile(in file: Foundation.NSFileHandle): void = raw objc {
  // Closing the descriptor releases flock. NSFileHandle also closes on final
  // release if setup ever exits before the explicit Z lease is constructed.
  (void)[file closeAndReturnError:NULL];
}

internal struct MacOSInstanceLease {
  file: Foundation.NSFileHandle;
  readonly identifier: String;

  deinit {
    closeInstanceFile(in this.file);
  }
}

// none means another descriptor holds the primary lease, not an I/O failure.
// The caller must forward to that primary or fail; it must never ignore an
// error and start an independent primary. This does not yet admit a launch.
internal function acquireMacOSInstanceLease(
  in identifier: String
): Option<MacOSInstanceLease> throws MacOSInstanceLeaseError {
  if (identifier.byteLength == 0) {
    throw MacOSInstanceLeaseError({ code: 0, message: "invalid single-instance application identifier" });
  }
  const nativeIdentifier: Foundation.NSString = copy identifier;
  let errorCode = 0;
  const file = acquireInstanceFile(in nativeIdentifier, inout errorCode);
  if (errorCode != 0) {
    throw MacOSInstanceLeaseError({ code: errorCode, message: "could not acquire the private application instance lease" });
  }
  if (file == null) return Option<MacOSInstanceLease>.none;
  return Option.some(MacOSInstanceLease({ file, identifier: copy identifier }));
}
