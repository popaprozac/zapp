import console from "std/console";
import process from "std/process";
import { sleep } from "std/time";
import {
  acquireMacOSInstanceLease,
  MacOSInstanceLeaseError,
} from "../framework/platform/macos/instance-lease.zs";

function hold(in identifier: String, wait: boolean): i32 throws MacOSInstanceLeaseError {
  const outcome = try acquireMacOSInstanceLease(in identifier);
  match (outcome) {
    some(lease) => {
      // Reopening the same path in the same process must not acquire it again.
      const duplicate = try acquireMacOSInstanceLease(in identifier);
      match (duplicate) {
        some(_) => return 10;
        none => {}
      }
      console.log("primary");
      if (wait) sleep(5000);
      return 0;
    }
    none => {
      console.log("secondary");
      return 2;
    }
  }
}

function main(): i32 {
  const arguments = process.args();
  if (arguments.length != 2) return 90;
  const identifier = copy arguments[0];
  const mode = copy arguments[1];
  if (mode == "release") {
    const first = match (attempt hold(in identifier, false)) {
      success(code) => code;
      failure(_) => return 3;
    };
    if (first != 0) return first;
  }
  return match (attempt hold(in identifier, mode == "hold")) {
    success(code) => code;
    failure(error) => {
      console.error(error.message);
      return 3;
    }
  };
}
