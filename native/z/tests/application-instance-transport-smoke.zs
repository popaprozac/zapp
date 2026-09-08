import console from "std/console";
import process from "std/process";
import { sleep } from "std/time";
import { ActivationInbox } from "../framework/activation-inbox.zs";
import { acquireMacOSInstanceLease } from "../framework/platform/macos/instance-lease.zs";
import {
  listenMacOSLaunches,
  forwardMacOSLaunch,
  forwardMacOSLaunchWhenReady,
} from "../framework/platform/macos/instance-transport.zs";

function serve(in identifier: String, in mode: String): i32 {
  const ownership = match (attempt acquireMacOSInstanceLease(in identifier)) {
    success(value) => value;
    failure(_) => return 3;
  };
  match (ownership) {
    none => { console.log("secondary"); return 2; }
    some(lease) => {
      if (mode == "late" || mode == "unready") {
        console.log("elected");
        sleep(u64(mode == "late" ? 250 : 8000));
        if (mode == "unready") return 0;
      }
      let endpoint = match (attempt listenMacOSLaunches(move lease)) {
        success(value) => value;
        failure(_) => return 4;
      };
      const inbox = new ActivationInbox();
      if (mode == "closed") inbox.close();
      console.log("ready");
      const count = mode == "batch" ? 66 : 1;
      let index = 0;
      while (index < count) {
        match (attempt endpoint.receive(in inbox)) {
          success(accepted) => {
            const status = accepted ? "accepted" : "rejected";
            console.log(status);
          }
          failure(error) => {
            const status = error.mayHaveBeenAdmitted ? "admitted-without-ack" : "failed";
            console.log(status);
          }
        }
        index = index + 1;
      }
      // Prove admission is independent of listeners and main-loop activity.
      let admitted = 0;
      while (true) {
        match (inbox.take()) {
          some(_) => { admitted = admitted + 1; }
          none => break;
        }
      }
      console.log(`queued ${admitted}`);
    }
  }
  return 0;
}

function main(): i32 {
  const arguments = process.args();
  if (arguments.length < 2) return 90;
  const identifier = copy arguments[0];
  const mode = copy arguments[1];
  if (mode == "send" || mode == "send-ready") {
    if (arguments.length != 3) return 91;
    const payload = copy arguments[2];
    const forwarded = mode == "send-ready"
      ? attempt forwardMacOSLaunchWhenReady(in identifier, in payload)
      : attempt forwardMacOSLaunch(in identifier, in payload);
    return match (forwarded) {
      success(accepted) => {
        const status = accepted ? "accepted" : "rejected";
        console.log(status);
        select accepted ? 0 : 5;
      }
      failure(error) => {
        const status = error.mayHaveBeenAdmitted ? "uncertain" : "unavailable";
        console.log(status);
        select error.mayHaveBeenAdmitted ? 7 : 6;
      }
    };
  }
  const result = serve(in identifier, in mode);
  if (result != 0) return result;
  // Endpoint scope cleanup must remove its socket and release its held lease
  // before this process exits, not just rely on kernel process cleanup.
  match (attempt acquireMacOSInstanceLease(in identifier)) {
    success(value) => match (value) {
      some(_) => console.log("released");
      none => return 8;
    }
    failure(_) => return 9;
  }
  return 0;
}
