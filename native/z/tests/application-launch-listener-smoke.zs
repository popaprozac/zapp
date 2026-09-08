import console from "std/console";
import process from "std/process";
import { TaskScope, scheduler } from "std/async";
import { Mutex, Once } from "std/sync";
import { thread } from "std/thread";
import nativeRunLoop from "CoreFoundation/CoreFoundation.h";
import nativeThread from "pthread.h";
import nativeProcess from "stdlib.h";
import { ActivationInbox } from "../framework/activation-inbox.zs";
import { acquireMacOSInstanceLease } from "../framework/platform/macos/instance-lease.zs";
import { MacOSLaunchEndpoint, listenMacOSLaunches } from "../framework/platform/macos/instance-transport.zs";

// This probe deliberately does not install the listener in Application yet.
// Only the checked inbox and a TaskScope cross threads; Foundation endpoint
// owners are created, used, and destroyed on the listener's worker.
function assertMain(): void = raw c { if (!pthread_main_np()) abort(); }
function assertWorker(): void = raw c { if (pthread_main_np()) abort(); }
// Exercise the same OS main-loop delivery used by AppKit. This is test-host
// plumbing, not a framework sleep/poll implementation or a replacement timer.
function pumpMain(milliseconds: i32): void = raw c {
  if (!pthread_main_np()) abort();
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, (double)milliseconds / 1000.0, false);
}

struct ListenerState {
  phase: i32;
  admitted: i32;
  rejectedWake: boolean;
  released: boolean;
}

readonly class ListenerStatus {
  readonly state: Mutex<ListenerState>;

  function phase(value: i32): void {
    this.state.withLock((inout state): void => { state.phase = value; });
  }
  function snapshot(): ListenerState {
    return this.state.withLock((in state): ListenerState => state);
  }
  function admit(): void {
    this.state.withLock((inout state): void => { state.admitted = state.admitted + 1; });
  }
  function rejectWake(): void {
    this.state.withLock((inout state): void => { state.rejectedWake = true; });
  }
  function release(): void {
    this.state.withLock((inout state): void => { state.released = true; });
  }
}

struct WorkerLifetime {
  status: ListenerStatus;
  deinit { assertWorker(); this.status.release(); }
}

class LaunchHost on thread.main {
  readonly inbox: ActivationInbox;
  delivered: i32;
  invalid: boolean;
  deinit { assertMain(); console.log("host released"); }

  function drain(inout this): void {
    assertMain();
    this.inbox.beginWake();
    while (true) {
      match (this.inbox.take()) {
        some(request) => match (request) {
          secondInstance(launch) => {
            if (launch.arguments.length != 3) this.invalid = true;
            else if (launch.arguments[0] != "" || launch.arguments[1] != "draft with spaces" || launch.arguments[2] != "資料") this.invalid = true;
            this.delivered = this.delivered + 1;
          }
          _ => { this.invalid = true; }
        }
        none => break;
      }
    }
  }
}

const host = Once<LaunchHost>();
function publishLaunches(): void on thread.main {
  let current = host.get();
  current.drain();
}

function openEndpoint(in identifier: String, status: ListenerStatus): MacOSLaunchEndpoint throws i32 {
  assertWorker();
  const elected = match (attempt acquireMacOSInstanceLease(in identifier)) {
    success(value) => value;
    failure(_) => { status.phase(4); throw 4; }
  };
  const lease = match (elected) {
    some(value) => value;
    none => { status.phase(3); throw 3; }
  };
  status.phase(1); // Election is not endpoint readiness.
  const endpoint = match (attempt listenMacOSLaunches(move lease)) {
    success(value) => value;
    failure(_) => { status.phase(4); throw 4; }
  };
  status.phase(2);
  return move endpoint;
}

function receiveLaunch(inout endpoint: MacOSLaunchEndpoint, inbox: ActivationInbox, updates: TaskScope, status: ListenerStatus): void {
  assertWorker();
  match (attempt endpoint.receive(in inbox)) {
    success(accepted) => { if (accepted) status.admit(); }
    // Admission survives a lost acknowledgement; never strand that request.
    failure(error) => { if (error.mayHaveBeenAdmitted) status.admit(); }
  }
  if (!inbox.reserveWake()) return;
  const wake = updates.schedule(thread.main, async (): void => publishLaunches());
  if (!wake.accepted) {
    inbox.beginWake();
    status.rejectWake();
  }
}

async function listen(identifier: String, inbox: ActivationInbox, updates: TaskScope, status: ListenerStatus): i32 {
  const lifetime = WorkerLifetime({ status });
  let endpoint = match (attempt openEndpoint(in identifier, status)) {
    success(value) => value;
    failure(code) => return code;
  };
  while (!inbox.isClosed()) {
    receiveLaunch(inout endpoint, inbox, updates, status);
    await scheduler.yield();
  }
  return 0;
}

function verifyLease(in identifier: String): boolean {
  return match (attempt acquireMacOSInstanceLease(in identifier)) {
    success(lease) => match (lease) { some(_) => true; none => false; }
    failure(_) => false;
  };
}

async function main(): i32 on thread.main {
  const arguments = process.args();
  if (arguments.length != 2) return 90;
  const identifier = copy arguments[0];
  const mode = copy arguments[1];
  const inbox = new ActivationInbox();
  const status = new ListenerStatus({ state: Mutex(ListenerState({
    phase: 0, admitted: 0, rejectedWake: false, released: false,
  })) });
  const hostLifetime = host.initialize(new LaunchHost({ inbox, delivered: 0, invalid: false }));
  const current = host.get();
  const updates = new TaskScope();
  if (mode == "closed-scope") await updates.close();
  const workerIdentifier = copy identifier;
  const listener = thread.spawn(async move (): i32 => await listen(move workerIdentifier, inbox, updates, status));
  let ticks = 0;
  while (status.snapshot().phase < 2 && ticks < 1000) {
    pumpMain(5);
    ticks = ticks + 1;
  }
  const phase = status.snapshot().phase;
  if (phase == 2) console.log("ready");
  else console.log(`startup ${phase}`);

  ticks = 0;
  if (phase == 2) {
    if (mode == "partial" || mode == "idle") pumpMain(150);
    else {
      while (ticks < 1000) {
        if (mode == "closed-scope") {
          if (status.snapshot().rejectedWake) break;
        } else if (current.delivered == 1) break;
        pumpMain(5);
        ticks = ticks + 1;
      }
    }
  }

  // The sequence under test: close admission, cancel + join the worker (its
  // socket is removed before its lease is released), join main work, then let
  // the main-owned host lifetime end. No destructor waits on a live listener.
  inbox.close();
  await listener.cancel();
  console.log("listener joined");
  await updates.close();
  console.log("updates joined");
  if (!status.snapshot().released) return 91;
  if (mode == "secondary") {
    if (verifyLease(in identifier)) return 92;
    console.log("primary preserved");
  } else {
    if (!verifyLease(in identifier)) return 92;
    console.log("lease released");
  }
  const expectedPhase = mode == "startup-failure" ? 4 : mode == "secondary" ? 3 : 2;
  if (phase != expectedPhase) return 93;
  if (current.invalid || ticks == 1000) return 94;
  const expected = mode == "normal" ? 1 : 0;
  if (current.delivered != expected) return 95;
  const expectedAdmitted = mode == "normal" || mode == "closed-scope" ? 1 : 0;
  if (status.snapshot().admitted != expectedAdmitted) return 96;
  console.log(`delivered ${current.delivered}`);
  return 0;
}
