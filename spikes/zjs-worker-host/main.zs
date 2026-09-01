import console from "std/console";
import { thread } from "std/thread";
import native from "zapp_worker_zjs.h";
import {
  WorkerEngine,
  WorkerLifecycle,
  WorkerModule,
  runWorkerEngine,
} from "./worker-engine.zs";

const workerModule: cstring = "setTimeout(() => { __zappServiceAdd(20, 22); }, 5);";

// This is the checked Z implementation reached directly from the embedded JS
// engine. The C ABI is an internal adapter seam, not a public application API.
export c function zapp_worker_probe_add(left: i32, right: i32): i32 {
  return left + right;
}

struct ZjsWorkerEngine implements WorkerEngine {
  handle: native.ZappZjsEngine;

  function load(
    inout this,
    in module: WorkerModule
  ): i32 {
    return native.zapp_zjs_engine_evaluate_module(
      this.handle,
      module.source
    );
  }

  function hasPendingWork(): boolean {
    return native.zapp_zjs_engine_has_pending_work(this.handle) != 0;
  }

  function nextWakeMilliseconds(): i64 {
    return native.zapp_zjs_engine_next_wake_milliseconds(this.handle);
  }

  function pump(inout this): i32 {
    return native.zapp_zjs_engine_pump(this.handle);
  }

  function result(): i32 {
    return native.zapp_zjs_engine_result(this.handle);
  }
}

function executeWorkerModule(): i32 {
  const engine = native.zapp_zjs_engine_create();
  if (engine == null) return -100;

  let adapter = ZjsWorkerEngine({ handle: move engine });
  const module = WorkerModule({ source: workerModule });
  return match (runWorkerEngine(inout adapter, in module)) {
    stopped(value) => value;
    failed(code) => -code;
  };
}

async function main(): i32 {
  const worker = thread.spawn((): i32 => executeWorkerModule());
  const result = await worker;
  console.log(`ZJS worker called Z directly and returned ${result}`);
  return result - 42;
}
