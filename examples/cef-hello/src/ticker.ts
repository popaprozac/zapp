// cef-hello ticker — the headless ZJS worker that proves worker→CEF broadcast
// delivery. Every second it emits a `tick` event via the host broadcast path
// (Events.emit → dispatch_event_to_all → darwin_webview_eval_all →
// zapp_registered_webviews_eval's ZAPP_HAS_CEF branch → the CEF page). No
// point-to-point send; a plain broadcast, which is exactly the edge sub-cycle A
// proves. The console.log gives non-visual evidence in bounded headless runs
// (`[zapp/ticker] tick N`).
import { Events } from "@zappdev/runtime";

let n = 0;
setInterval(() => {
  n += 1;
  console.log(`tick ${n}`);
  Events.emit("tick", { n });
}, 1000);
