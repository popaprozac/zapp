import { thread } from "std/thread";
import { ActivationInbox } from "../framework/activation-inbox.zs";

function produce(in inbox: ActivationInbox): i32 {
  let accepted = 0;
  let index = 0;
  while (index < 100) {
    if (inbox.admitPayload(
      '{"version":1,"launch":{"arguments":[],"workingDirectory":null}}'
    )) accepted = accepted + 1;
    index = index + 1;
  }
  return accepted;
}

async function main(): i32 {
  const inbox = new ActivationInbox();
  const first = thread.spawn(move (): i32 => produce(in inbox));
  const second = thread.spawn(move (): i32 => produce(in inbox));
  const third = thread.spawn(move (): i32 => produce(in inbox));
  const a = await first;
  const b = await second;
  const c = await third;
  return a + b + c - 64;
}
