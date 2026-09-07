import console from "std/console";
import { thread } from "std/thread";
import {
  ApplicationSecondInstanceLaunchedEvent,
  decodeApplicationLaunch,
  encodeApplicationLaunch,
  validApplicationLaunch,
} from "../framework/application-launch.zs";
import {
  ApplicationOpenURLRequestedEvent,
  ApplicationReopenRequestedEvent,
} from "../framework/application-activation.zs";
import {
  ApplicationEventSubscriptionError,
  ApplicationQuitRequestedEvent,
  createApplicationEvents,
} from "../framework/application-events.zs";

function snapshot(
  arguments: Array<String>,
  workingDirectory: Option<String>
): ApplicationSecondInstanceLaunchedEvent {
  return ApplicationSecondInstanceLaunchedEvent({
    arguments: arguments.freeze(),
    workingDirectory: move workingDirectory,
  });
}

function emptyLaunch(): ApplicationSecondInstanceLaunchedEvent {
  return snapshot(Array<String>(), Option<String>.none);
}

function rejects(in source: String): boolean {
  return match (attempt decodeApplicationLaunch(in source)) {
    success(_) => false;
    failure(_) => true;
  };
}

function protocolChecks(): i32 {
  const launch = snapshot(
    Array<String>("--open", "", "draft with spaces.md", "資料", "znotes://notes/1"),
    Option<String>.some("/tmp/資料 with spaces")
  );
  const encoded = match (attempt encodeApplicationLaunch(move launch)) {
    success(value) => value;
    failure(_) => return 1;
  };
  const decoded = match (attempt decodeApplicationLaunch(in encoded)) {
    success(value) => value;
    failure(_) => return 2;
  };
  if (decoded.arguments.length != 5) return 3;
  if (decoded.arguments[0] != "--open" || decoded.arguments[1] != "") return 4;
  if (decoded.arguments[2] != "draft with spaces.md" || decoded.arguments[3] != "資料") return 5;
  if (decoded.arguments[4] != "znotes://notes/1") return 6;
  match (in decoded.workingDirectory) {
    some(directory) => { if (directory != "/tmp/資料 with spaces") return 7; }
    none => return 8;
  }

  const emptyEncoded = match (attempt encodeApplicationLaunch(emptyLaunch())) {
    success(value) => value;
    failure(_) => return 9;
  };
  if (emptyEncoded != '{"version":1,"launch":{"arguments":[],"workingDirectory":null}}') return 23;
  const empty = match (attempt decodeApplicationLaunch(in emptyEncoded)) {
    success(value) => value;
    failure(_) => return 10;
  };
  if (empty.arguments.length != 0) return 11;
  match (in empty.workingDirectory) {
    some(_) => return 12;
    none => {}
  }

  let invalid = Array<String>(
    "",
    "null",
    "{}",
    `{"version":2,"launch":{"arguments":[],"workingDirectory":null}}`,
    `{"version":1,"launch":{"arguments":"not an array","workingDirectory":null}}`,
    `{"version":1,"launch":{"arguments":[1],"workingDirectory":null}}`,
    `{"version":1,"launch":{"arguments":[],"workingDirectory":false}}`,
    `{"version":1,"launch":{"arguments":[],"workingDirectory":""}}`,
    `{"version":1,"launch":{"arguments":[]}}`,
    `{"version":1,"launch":null}`,
    `{"version":1,"launch":{"arguments":[],"workingDirectory":null}} trailing`,
    `{"version":1,"version":1,"launch":{"arguments":[],"workingDirectory":null}}`,
    `{"version":1,"launch":{"arguments":[],"workingDirectory":null,"workingDirectory":"/tmp"}}`
  );
  for (const source of invalid) {
    if (!rejects(in source)) return 13;
  }
  // JSON escapes must not smuggle native NULs into arguments or paths.
  const nulArgument = "{\"version\":1,\"launch\":{\"arguments\":[\"private\\u0000argument\"],\"workingDirectory\":null}}";
  const nulDirectory = "{\"version\":1,\"launch\":{\"arguments\":[],\"workingDirectory\":\"/private\\u0000path\"}}";
  if (!rejects(in nulArgument) || !rejects(in nulDirectory)) return 14;

  let maximum = Array<String>();
  let index: usize = 0;
  while (index < 256) {
    maximum.push("");
    index = index + 1;
  }
  const accepted = snapshot(move maximum, Option<String>.none);
  if (!validApplicationLaunch(in accepted)) return 15;
  let excessive = Array<String>();
  index = 0;
  while (index < 257) {
    excessive.push("");
    index = index + 1;
  }
  const denied = snapshot(move excessive, Option<String>.none);
  if (validApplicationLaunch(in denied)) return 16;
  match (attempt encodeApplicationLaunch(move denied)) {
    success(_) => return 17;
    failure(_) => {}
  }
  let text = "x";
  while (text.byteLength < 16384) { text = `${text}${text}`; }
  const boundary = snapshot(Array<String>(copy text), Option<String>.none);
  if (!validApplicationLaunch(in boundary)) return 18;
  const tooLong = snapshot(Array<String>(`${text}x`), Option<String>.none);
  if (validApplicationLaunch(in tooLong)) return 19;
  const total = snapshot(Array<String>(copy text, copy text, copy text, copy text, "x"), Option<String>.none);
  if (validApplicationLaunch(in total)) return 20;
  // JSON framing and escaping count toward the transport byte limit too.
  const exactTotal = snapshot(Array<String>(copy text, copy text, copy text, copy text), Option<String>.none);
  match (attempt encodeApplicationLaunch(move exactTotal)) {
    success(_) => return 21;
    failure(_) => {}
  }
  let oversized = `${text}${text}${text}${text}x`;
  if (!rejects(in oversized)) return 22;
  return 0;
}

class Trace on thread.main {
  sequence: i32;
  launches: i32;
  reopens: i32;
  urls: i32;
  argument: String;
}

function eventChecks(): i32 throws ApplicationEventSubscriptionError on thread.main {
  const events = createApplicationEvents();
  events.configureActivation(Array<String>("znotes"));
  const trace = new Trace({ sequence: 0, launches: 0, reopens: 0, urls: 0, argument: "" });
  const nested = events;
  const launchHandler: (in event: ApplicationSecondInstanceLaunchedEvent) => void on thread.main =
    move (in event: ApplicationSecondInstanceLaunchedEvent): void => {
      trace.launches = trace.launches + 1;
      trace.sequence = trace.sequence * 10 + 2;
      if (event.arguments.length > 0) {
        trace.argument = copy event.arguments[0];
        nested.requestReopen();
      }
    };
  const launches = try events.secondInstanceLaunched.subscribe(launchHandler);
  const reopen = try events.reopenRequested.subscribe(
    move (in event: ApplicationReopenRequestedEvent): void => {
      trace.reopens = trace.reopens + 1;
      trace.sequence = trace.sequence * 10 + 1;
    }
  );
  const urls = try events.openURLRequested.subscribe(
    move (in event: ApplicationOpenURLRequestedEvent): void => {
      trace.urls = trace.urls + 1;
      trace.sequence = trace.sequence * 10 + 3;
    }
  );
  events.requestReopen();
  events.requestSecondInstance(snapshot(Array<String>("znotes://notes/1"), Option<String>.none));
  events.requestOpenURL("znotes://notes/2");
  if (trace.sequence != 0) return 31;
  events.startActivation();
  if (trace.sequence != 1231) return 32;
  if (trace.launches != 1 || trace.reopens != 2 || trace.urls != 1) return 33;
  if (trace.argument != "znotes://notes/1") return 34;
  // No implicit URL/reopen event, even for an empty secondary launch.
  events.requestSecondInstance(emptyLaunch());
  if (trace.launches != 2 || trace.reopens != 2 || trace.urls != 1) return 35;
  launches.unsubscribe();
  events.requestSecondInstance(emptyLaunch());
  if (trace.launches != 2) return 36;
  events.finish();
  if (events.requestSecondInstance(emptyLaunch())) return 37;

  const bounded = createApplicationEvents();
  let index: usize = 0;
  while (index < 63) {
    if (!bounded.requestReopen()) return 38;
    index = index + 1;
  }
  if (!bounded.requestSecondInstance(emptyLaunch())) return 39;
  if (bounded.requestSecondInstance(emptyLaunch())) return 40;
  bounded.startActivation();
  const late = try bounded.secondInstanceLaunched.subscribe(
    move (in event: ApplicationSecondInstanceLaunchedEvent): void => { trace.launches = trace.launches + 1; }
  );
  if (trace.launches != 2) return 41;
  if (!bounded.requestSecondInstance(emptyLaunch()) || trace.launches != 3) return 42;
  bounded.finish();

  const cancelled = createApplicationEvents();
  const abandoned = try cancelled.secondInstanceLaunched.subscribe(
    move (in event: ApplicationSecondInstanceLaunchedEvent): void => { trace.launches = -1; }
  );
  cancelled.start(move (): void => {});
  const veto = try cancelled.quitRequested.subscribe(
    (in event: ApplicationQuitRequestedEvent): void => event.cancel()
  );
  cancelled.requestQuit();
  if (!cancelled.requestSecondInstance(emptyLaunch())) return 43;
  veto.unsubscribe();
  cancelled.requestQuit();
  if (cancelled.requestSecondInstance(emptyLaunch())) return 44;
  cancelled.startActivation();
  if (trace.launches != 3) return 45;
  cancelled.finish();
  return 0;
}

function main(): i32 on thread.main {
  const protocol = protocolChecks();
  if (protocol != 0) return protocol;
  const events = match (attempt eventChecks()) {
    success(status) => status;
    failure(_) => 99;
  };
  if (events == 0) console.log("secondary launch payload and event checks passed");
  return events;
}
