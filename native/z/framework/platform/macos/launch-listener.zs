import Foundation from "Foundation/Foundation.h";
import process from "std/process";
import { Sender, SyncSender } from "std/channel";
import { TaskScope, scheduler } from "std/async";
import { thread } from "std/thread";
import { ActivationInbox } from "../../activation-inbox.zs";
import { ApplicationSecondInstanceLaunchedEvent, encodeApplicationLaunch } from "../../application-launch.zs";
import { acquireMacOSInstanceLease } from "./instance-lease.zs";
import {
  MacOSLaunchEndpoint, MacOSLaunchTransportError,
  listenMacOSLaunches, forwardMacOSLaunchWhenReady,
} from "./instance-transport.zs";
import { deliverMacOSLaunches } from "./launch-delivery.zs";

internal enum MacOSLaunchReadiness {
  primary,
  forwarded,
  failure MacOSLaunchTransportError,
}

function reportLaunchReadiness(ready: SyncSender<MacOSLaunchReadiness>, value: MacOSLaunchReadiness): void {
  // A gone receiver means the caller abandoned startup. No fallback primary.
  const sent = attempt ready.send(move value);
}

function forwardCurrentLaunch(in identifier: String): void throws MacOSLaunchTransportError {
  const arguments = process.args();
  const directory: String = Foundation.NSFileManager.defaultManager.currentDirectoryPath;
  const snapshot = ApplicationSecondInstanceLaunchedEvent({
    arguments: arguments.freeze(),
    workingDirectory: directory.byteLength > 0 ? Option.some(move directory) : Option<String>.none,
  });
  const payload = match (attempt encodeApplicationLaunch(move snapshot)) {
    success(value) => value;
    failure(error) => {
      const { message } = move error;
      throw MacOSLaunchTransportError({ code: 0, mayHaveBeenAdmitted: false, message });
    }
  };
  const accepted = try forwardMacOSLaunchWhenReady(in identifier, in payload);
  if (!accepted) {
    throw MacOSLaunchTransportError({ code: 0, mayHaveBeenAdmitted: false, message: "primary application rejected the secondary launch" });
  }
}

function openPrimaryEndpoint(
  in identifier: String, ready: SyncSender<MacOSLaunchReadiness>
): Option<MacOSLaunchEndpoint> throws MacOSLaunchTransportError {
  const elected = match (attempt acquireMacOSInstanceLease(in identifier)) {
    success(value) => value;
    failure(error) => {
      const { code, message } = move error;
      throw MacOSLaunchTransportError({ code, mayHaveBeenAdmitted: false, message });
    }
  };
  return match (elected) {
    some(lease) => {
      const endpoint = try listenMacOSLaunches(move lease);
      select Option.some(move endpoint);
    }
    none => {
      try forwardCurrentLaunch(in identifier);
      reportLaunchReadiness(ready, MacOSLaunchReadiness.forwarded);
      select Option<MacOSLaunchEndpoint>.none;
    }
  };
}

function receiveLaunch(inout endpoint: MacOSLaunchEndpoint, inbox: ActivationInbox, updates: TaskScope): void {
  // Even a lost acknowledgement may follow successful admission. Always
  // inspect the inbox, and never replay a possibly admitted request.
  const received = attempt endpoint.receive(in inbox);
  if (!inbox.reserveWake()) return;
  const wake = updates.schedule(thread.main, async (): void => deliverMacOSLaunches());
  if (!wake.accepted) inbox.beginWake();
}

internal async function listenMacOSApplicationLaunches(
  identifier: String, inbox: ActivationInbox, updates: TaskScope,
  sender: Sender<MacOSLaunchReadiness>
): i32 {
  const ready = sender.sync();
  let endpoint = match (attempt openPrimaryEndpoint(in identifier, ready)) {
    success(selected) => match (selected) {
      some(value) => value;
      none => return 0;
    }
    failure(error) => {
      reportLaunchReadiness(ready, MacOSLaunchReadiness.failure(move error));
      return 1;
    }
  };
  reportLaunchReadiness(ready, MacOSLaunchReadiness.primary);
  while (!inbox.isClosed()) {
    receiveLaunch(inout endpoint, inbox, updates);
    await scheduler.yield();
  }
  return 0;
}

// Move captures retain Sender handles. End the parent's alias after spawning,
// so worker completion without a report closes readiness rather than hanging.
internal function releaseMacOSLaunchSender(
  sender: Sender<MacOSLaunchReadiness>
): void {
}
