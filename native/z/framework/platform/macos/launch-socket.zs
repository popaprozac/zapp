import Foundation from "Foundation/Foundation.h";
import sockets from "sys/socket.h";
import local from "sys/un.h";
import status from "sys/stat.h";
import descriptors from "fcntl.h";
import system from "unistd.h";
import polling from "poll.h";
import errors from "errno.h";
import time from "time.h";
import digest from "CommonCrypto/CommonDigest.h";

// OS mechanics only. Protocol validation, admission, and lifetimes live in Z.
// This namespace is cooperative same-user coordination, not authentication of
// one application against other programs running under the same effective UID.
internal function launchSocketPath(
  in identifier: Foundation.NSString,
  inout errorCode: i32
): Foundation.NSString | null = raw objc {
  *errorCode = 0;
  // sockaddr_un is too short for arbitrary Darwin private-temp paths plus a
  // full SHA-256 name. Use a checked, private per-user directory under the
  // canonical system temporary root. Never honor TMPDIR or shorten the digest.
  char directory[64];
  int length = snprintf(directory, sizeof(directory), "/private/tmp/zapp-launch-%u", (unsigned)geteuid());
  if (length < 0 || (size_t)length >= sizeof(directory)) { *errorCode = ENAMETOOLONG; return nil; }
  if (mkdir(directory, 0700) != 0 && errno != EEXIST) { *errorCode = errno; return nil; }
  int parent = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (parent < 0) { *errorCode = errno; return nil; }
  struct stat info;
  bool valid = fstat(parent, &info) == 0 && S_ISDIR(info.st_mode)
    && info.st_uid == geteuid() && (info.st_mode & 077) == 0;
  close(parent);
  if (!valid) { *errorCode = EPERM; return nil; }
  NSData *bytes = [identifier dataUsingEncoding:NSUTF8StringEncoding];
  if (bytes == nil || bytes.length == 0 || bytes.length > UINT32_MAX) { *errorCode = EINVAL; return nil; }
  unsigned char hash[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, hash);
  char name[CC_SHA256_DIGEST_LENGTH * 2 + 1];
  const char *hex = "0123456789abcdef";
  for (size_t index = 0; index < sizeof(hash); index++) {
    name[index * 2] = hex[hash[index] >> 4];
    name[index * 2 + 1] = hex[hash[index] & 15];
  }
  name[sizeof(name) - 1] = 0;
  NSString *path = [NSString stringWithFormat:@"%s/%s", directory, name];
  if (strlen(path.fileSystemRepresentation) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
    *errorCode = ENAMETOOLONG; return nil;
  }
  return path;
}

internal function launchDeadline(milliseconds: i32): f64 = raw c {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
  return (double)now.tv_sec + (double)now.tv_nsec / 1e9 + (double)milliseconds / 1000.0;
}

// Only connect-before-send may wait for a newly elected primary's endpoint.
// Never retry a request or turn readiness failure into another primary.
internal function retryLaunchConnection(code: i32, deadline: f64): boolean = raw c {
  if (code != ENOENT && code != ECONNREFUSED && code != EAGAIN) return false;
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return false;
  double remaining = deadline - ((double)now.tv_sec + (double)now.tv_nsec / 1e9);
  if (!(remaining > 0)) return false;
  struct timespec pause = { .tv_sec = 0, .tv_nsec = remaining > 0.01 ? 10000000 : (long)(remaining * 1e9) };
  (void)nanosleep(&pause, NULL);
  return true;
}

internal function waitLaunchSocket(
  in file: Foundation.NSFileHandle,
  writing: boolean,
  deadline: f64
): i32 = raw objc {
  while (true) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return errno;
    double remaining = deadline - ((double)now.tv_sec + (double)now.tv_nsec / 1e9);
    if (!(remaining > 0)) return ETIMEDOUT;
    // Deadlines are internal and at most five seconds; clamp defensively.
    int milliseconds = remaining > 5.0 ? 5000 : (int)(remaining * 1000.0) + 1;
    struct pollfd item = { .fd = file.fileDescriptor, .events = writing ? POLLOUT : POLLIN };
    int result = poll(&item, 1, milliseconds);
    if (result < 0 && errno == EINTR) continue;
    if (result < 0) return errno;
    if (result == 0) continue;
    if (item.revents & POLLNVAL) return EBADF;
    // EOF and errors are consumed by the nonblocking read/write/connect check.
    if (item.revents & (item.events | POLLHUP | POLLERR)) return 0;
  }
}

internal function openLaunchSocket(
  in path: Foundation.NSString,
  listening: boolean,
  inout errorCode: i32
): Foundation.NSFileHandle | null = raw objc {
  *errorCode = 0;
  const char *name = path.fileSystemRepresentation;
  struct sockaddr_un address = {0};
  if (name == NULL || strlen(name) >= sizeof(address.sun_path)) { *errorCode = ENAMETOOLONG; return nil; }
  address.sun_family = AF_UNIX;
  address.sun_len = sizeof(address);
  strcpy(address.sun_path, name);
  struct stat existing;
  if (lstat(name, &existing) == 0) {
    if (!S_ISSOCK(existing.st_mode) || existing.st_uid != geteuid()
        || (existing.st_mode & 077) != 0 || existing.st_nlink != 1) {
      *errorCode = EPERM; return nil;
    }
    // Only the Z endpoint constructor, holding the exclusive lease, uses this
    // branch. Stale sockets are not stale lock files: the latter stay intact.
    if (listening && unlink(name) != 0) { *errorCode = errno; return nil; }
  } else if (errno != ENOENT || !listening) { *errorCode = errno; return nil; }
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) { *errorCode = errno; return nil; }
  int one = 1;
  if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0 || fcntl(fd, F_SETFL, O_NONBLOCK) != 0
      || setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) != 0) {
    *errorCode = errno; close(fd); return nil;
  }
  if (listening) {
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) { *errorCode = errno; close(fd); return nil; }
    if (chmod(name, 0600) != 0 || listen(fd, 16) != 0) {
      *errorCode = errno; close(fd); unlink(name); return nil;
    }
  } else if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0 && errno != EINPROGRESS) {
    *errorCode = errno; close(fd); return nil;
  }
  NSFileHandle *owner = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
  if (owner == nil) { *errorCode = ENOMEM; close(fd); if (listening) unlink(name); }
  return owner;
}

internal function checkLaunchPeer(in file: Foundation.NSFileHandle): i32 = raw objc {
  int error = 0;
  socklen_t length = sizeof(error);
  if (getsockopt(file.fileDescriptor, SOL_SOCKET, SO_ERROR, &error, &length) != 0) return errno;
  if (error != 0) return error;
  uid_t user;
  gid_t group;
  if (getpeereid(file.fileDescriptor, &user, &group) != 0) return errno;
  return user == geteuid() ? 0 : EPERM;
}

internal function acceptLaunchSocket(
  in listener: Foundation.NSFileHandle,
  inout errorCode: i32
): Foundation.NSFileHandle | null = raw objc {
  *errorCode = 0;
  int fd = accept(listener.fileDescriptor, NULL, NULL);
  if (fd < 0) { *errorCode = errno; return nil; }
  int one = 1;
  if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0 || fcntl(fd, F_SETFL, O_NONBLOCK) != 0
      || setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) != 0) {
    *errorCode = errno; close(fd); return nil;
  }
  NSFileHandle *owner = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
  if (owner == nil) { *errorCode = ENOMEM; close(fd); }
  return owner;
}

internal function closeLaunchSocket(in file: Foundation.NSFileHandle): void = raw objc {
  (void)[file closeAndReturnError:NULL];
}

internal function removeLaunchSocket(in path: Foundation.NSString): void = raw objc {
  // The endpoint still owns the lease here. No cooperative replacement can be
  // installed until after this unlink and descriptor cleanup have completed.
  (void)unlink(path.fileSystemRepresentation);
}

internal function receiveLaunchChunk(
  in file: Foundation.NSFileHandle,
  inout data: Foundation.NSMutableData,
  offset: usize
): isize = raw objc {
  if (offset >= (*data).length) return -EINVAL;
  ssize_t result = recv(file.fileDescriptor, (uint8_t *)(*data).mutableBytes + offset, (*data).length - offset, 0);
  if (result < 0) return (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) ? 0 : -errno;
  return result == 0 ? -ECONNRESET : result;
}

internal function sendLaunchChunk(
  in file: Foundation.NSFileHandle,
  in data: Foundation.NSData,
  offset: usize
): isize = raw objc {
  if (offset >= data.length) return -EINVAL;
  ssize_t result = send(file.fileDescriptor, (const uint8_t *)data.bytes + offset, data.length - offset, 0);
  if (result < 0) return (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) ? 0 : -errno;
  return result == 0 ? -ECONNRESET : result;
}

internal function makeLaunchBuffer(length: usize): Foundation.NSMutableData = raw objc {
  return [NSMutableData dataWithLength:length];
}

internal function launchHeaderLength(in header: Foundation.NSData): usize = raw objc {
  if (header.length != 4) return 0;
  const uint8_t *bytes = header.bytes;
  return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | bytes[3];
}

internal function launchHeader(length: usize): Foundation.NSData = raw objc {
  uint8_t bytes[4] = { (uint8_t)(length >> 24), (uint8_t)(length >> 16), (uint8_t)(length >> 8), (uint8_t)length };
  return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

internal function launchTextBytes(in text: Foundation.NSString): Foundation.NSData = raw objc {
  return [text dataUsingEncoding:NSUTF8StringEncoding];
}

internal function launchBytesText(in data: Foundation.NSData): Foundation.NSString | null = raw objc {
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}
