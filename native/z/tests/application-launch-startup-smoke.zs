import console from "std/console";
import process from "std/process";
import { Channel } from "std/channel";
import { TaskScope } from "std/async";
import { thread } from "std/thread";
import runLoop from "CoreFoundation/CoreFoundation.h";
import nativeThread from "pthread.h";
import nativeProcess from "stdlib.h";
import Foundation from "Foundation/Foundation.h";
import errors from "sys/errno.h";
import { createApplicationEvents } from "../framework/application-events.zs";
import { ApplicationSecondInstanceLaunchedEvent } from "../framework/application-launch.zs";
import { initializeMacOSLaunchDelivery } from "../framework/platform/macos/launch-delivery.zs";
import { MacOSLaunchReadiness, listenMacOSApplicationLaunches, releaseMacOSLaunchSender } from "../framework/platform/macos/launch-listener.zs";
import { acquireMacOSInstanceLease } from "../framework/platform/macos/instance-lease.zs";
import { MacOSLaunchCancellation } from "../framework/platform/macos/launch-cancellation.zs";
import { launchDeadline } from "../framework/platform/macos/launch-socket.zs";

function pumpMain(milliseconds: i32): void = raw c {
  if (!pthread_main_np()) abort();
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, (double)milliseconds / 1000.0, false);
}

class Observation on thread.main {
  count: i32;
  valid: boolean;
}

function leaseAvailable(in identifier: String): boolean {
  return match (attempt acquireMacOSInstanceLease(in identifier)) {
    success(lease) => match (lease) { some(_) => true; none => false; }
    failure(_) => false;
  };
}

function verifyStickyCancellation(): boolean {
  const cancellation = match (attempt MacOSLaunchCancellation.create()) {
    success(value) => value;
    failure(_) => return false;
  };
  // More than the pipe capacity: requests must remain nonblocking and sticky.
  let index = 0;
  while (index < 100000) { cancellation.request(); index = index + 1; }
  const file = Foundation.NSFileHandle.fileHandleWithNullDevice;
  // /dev/null is also ready, so cancellation must win both readiness races.
  const first = cancellation.wait(in file, false, launchDeadline(1));
  const second = cancellation.wait(in file, false, launchDeadline(1));
  return first == errors.ECANCELED && second == errors.ECANCELED;
}

async function main(): i32 on thread.main {
  const arguments = process.args();
  if (arguments.length < 2) return 90;
  const identifier = copy arguments[0];
  const mode = copy arguments[1];
  if (mode == "sticky" && !verifyStickyCancellation()) return 99;
  const events = createApplicationEvents();
  const observed = new Observation({ count: 0, valid: true });
  const subscribed = attempt events.secondInstanceLaunched.subscribe(move (in event: ApplicationSecondInstanceLaunchedEvent): void => {
    observed.count = observed.count + 1;
    if (event.arguments.length != 5) observed.valid = false;
    else if (event.arguments[1] != "secondary" || event.arguments[2] != "" || event.arguments[3] != "draft with spaces" || event.arguments[4] != "資料") observed.valid = false;
    match (in event.workingDirectory) {
      some(directory) => { if (directory.byteLength == 0) observed.valid = false; }
      none => { observed.valid = false; }
    }
  });
  const subscription = match (subscribed) { success(value) => value; failure(_) => return 91; };
  const deliveryLifetime = initializeMacOSLaunchDelivery(events);
  const inbox = events.activationInbox();
  const updates = new TaskScope();
  const { sender, receiver } = Channel<MacOSLaunchReadiness>.bounded(1);
  const readiness = receiver.sync();
  const cancellation = match (attempt MacOSLaunchCancellation.create()) {
    success(value) => value;
    failure(_) => return 97;
  };
  const workerIdentifier = copy identifier;
  const worker = thread.spawn(async move (): i32 => await listenMacOSApplicationLaunches(move workerIdentifier, inbox, updates, sender, cancellation));
  releaseMacOSLaunchSender(move sender);
  const startup = readiness.receive();
  let phase = 0;
  match (startup) {
    some(state) => match (state) {
      primary => { phase = 1; }
      forwarded => { phase = 2; }
      failure(_) => { phase = 3; }
    }
    none => { phase = 4; }
  }
  // The channel reports actual endpoint readiness, without a polling flag.
  if (phase == 1) console.log("ready");
  else if (phase == 2) console.log("forwarded");
  else console.log("failed");
  let ticks = 0;
  if (phase == 1) {
    events.startActivation();
    if (mode == "idle" || mode == "partial" || mode == "partial-body" || mode == "sticky") pumpMain(150);
    else while (observed.count == 0 && ticks < 1000) { pumpMain(5); ticks = ticks + 1; }
  }
  events.finish();
  const began = launchDeadline(0);
  inbox.close();
  cancellation.request();
  cancellation.request(); // Sticky and safe even before the worker polls again.
  await worker.cancel();
  const elapsed = (launchDeadline(0) - began) * 1000;
  console.log(`cancellation joined in ${elapsed}ms`);
  if (elapsed > 400) return 98;
  console.log("listener joined");
  await updates.cancel();
  console.log("delivery joined");
  if (mode == "secondary") {
    if (phase != 2 || observed.count != 0) return 92;
  } else {
    if (!leaseAvailable(in identifier)) return 93;
    if (phase != (mode == "startup-failure" ? 3 : 1)) return 94;
    if (observed.count != (mode == "normal" ? 1 : 0)) return 95;
  }
  if (!observed.valid || ticks == 1000) return 96;
  console.log(`delivered ${observed.count}`);
  return 0;
}
