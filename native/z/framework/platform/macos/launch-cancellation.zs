import Foundation from "Foundation/Foundation.h";
import system from "unistd.h";
import descriptors from "fcntl.h";
import errors from "errno.h";
import { Mutex } from "std/sync";
import { thread } from "std/thread";
import { waitCancellableLaunchSocket } from "./launch-socket.zs";

// This move-only payload is the sole descriptor owner. Shared Mutex handles
// keep it alive across request/wait; neither operation closes or replaces an fd.
struct LaunchWakePipe {
  read: i32;
  write: i32;
  deinit on thread.any { closeWakePipe(this.read, this.write); }
}

function openWakePipe(inout read: i32, inout write: i32): i32 = raw c {
  int pair[2];
  if (pipe(pair) != 0) return errno;
  for (int index = 0; index < 2; index++) {
    if (fcntl(pair[index], F_SETFD, FD_CLOEXEC) != 0
        || fcntl(pair[index], F_SETFL, O_NONBLOCK) != 0) {
      int code = errno;
      close(pair[0]); close(pair[1]);
      return code;
    }
  }
  *read = pair[0]; *write = pair[1];
  return 0;
}

function closeWakePipe(read: i32, write: i32): void = raw c {
  // Both ends outlive every wait/request. Never close an active polled fd.
  (void)close(read);
  (void)close(write);
}

function signalWakePipe(descriptor: i32): void = raw c {
  const unsigned char byte = 1;
  while (write(descriptor, &byte, sizeof(byte)) < 0) {
    if (errno == EINTR) continue;
    // A full pipe is already readable: cancellation remains signalled.
    if (errno == EAGAIN || errno == EWOULDBLOCK) return;
    // The owned pipe cannot lose its reader while this operation is live.
    abort();
  }
}

internal readonly class MacOSLaunchCancellation {
  private readonly pipe: Mutex<LaunchWakePipe>;

  internal constructor(pipe: LaunchWakePipe) {
    this.pipe = Mutex(move pipe);
  }

  static function create(): MacOSLaunchCancellation throws i32 {
    let read: i32 = -1;
    let write: i32 = -1;
    const code = openWakePipe(inout read, inout write);
    if (code != 0) throw code;
    return new MacOSLaunchCancellation(LaunchWakePipe({ read, write }));
  }

  // Sticky, nonblocking and safe to repeat; no drain can lose a cancellation.
  function request(): void {
    this.pipe.withLock((in state): void => signalWakePipe(state.write));
  }

  function wait(in file: Foundation.NSFileHandle, writing: boolean, deadline: f64): i32 {
    const descriptor = this.pipe.withLock((in state): i32 => state.read);
    // Release the mutex before poll so request() never waits behind I/O.
    // The enclosing receiver loan retains the pipe owner for the whole wait.
    return waitCancellableLaunchSocket(in file, writing, deadline, descriptor);
  }
}
