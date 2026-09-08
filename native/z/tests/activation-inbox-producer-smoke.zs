import { thread } from "std/thread";
import { ActivationInbox } from "../framework/activation-inbox.zs";

struct ProducerResult {
  accepted: i32;
  wakes: i32;
}

function produce(in inbox: ActivationInbox): ProducerResult {
  let accepted = 0;
  let wakes = 0;
  let index = 0;
  while (index < 100) {
    if (inbox.admitPayload(
      '{"version":1,"launch":{"arguments":[],"workingDirectory":null}}'
    )) accepted = accepted + 1;
    if (inbox.reserveWake()) wakes = wakes + 1;
    index = index + 1;
  }
  return ProducerResult({ accepted, wakes });
}

async function main(): i32 {
  const inbox = new ActivationInbox();
  const first = thread.spawn(move (): ProducerResult => produce(in inbox));
  const second = thread.spawn(move (): ProducerResult => produce(in inbox));
  const third = thread.spawn(move (): ProducerResult => produce(in inbox));
  const a = await first;
  const b = await second;
  const c = await third;
  // All concurrent producers share one queued wake, not one wake per payload.
  if (a.accepted + b.accepted + c.accepted != 64) return 1;
  if (a.wakes + b.wakes + c.wakes != 1) return 6;
  if (inbox.reserveWake()) return 2;
  inbox.beginWake();
  if (!inbox.reserveWake()) return 3;
  if (inbox.reserveWake()) return 4;
  inbox.close();
  inbox.beginWake();
  if (inbox.reserveWake()) return 5;
  return 0;
}
