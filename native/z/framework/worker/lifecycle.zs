import { thread } from "std/thread";

// Engine adapters report lifecycle transitions from their own thread. The
// platform boundary copies these values and schedules publication on main.
export type ApplicationWorkerLifecycleHandler = (
  workerId: String,
  phase: i32,
  incarnation: u64,
  retry: u64,
  maxRetries: u64,
  withinMilliseconds: u64,
  message: String
) => void on thread.any;
