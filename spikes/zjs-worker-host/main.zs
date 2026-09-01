import console from "std/console";
import { thread } from "std/thread";
import native from "zapp_worker_zjs.h";

const workerModule: cstring = "export const result = __zappServiceAdd(20, 22);";

// This is the checked Z implementation reached directly from the embedded JS
// engine. The C ABI is an internal adapter seam, not a public application API.
export c function zapp_worker_probe_add(left: i32, right: i32): i32 {
  return left + right;
}

function executeWorkerModule(): i32 {
  const engine = native.zapp_zjs_engine_create();
  if (engine == null) return -100;

  const status = native.zapp_zjs_engine_evaluate_module(in engine, workerModule);
  if (status != 0) return -status;

  return native.zapp_zjs_engine_result(in engine);
}

async function main(): i32 {
  const worker = thread.spawn((): i32 => executeWorkerModule());
  const result = await worker;
  console.log(`ZJS worker called Z directly and returned ${result}`);
  return result - 42;
}
