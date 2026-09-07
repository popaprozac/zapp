import { Map } from "std/collections";
import { thread } from "std/thread";
import { Event } from "./events.zs";
import {
  ApplicationSecondInstanceLaunchedEvent,
  validApplicationLaunch,
} from "./application-launch.zs";

export readonly struct ApplicationReopenRequestedEvent {}

export readonly struct ApplicationOpenURLRequestedEvent {
  url: String;
}

enum ActivationRequest {
  reopen,
  openURL String,
  secondInstance ApplicationSecondInstanceLaunchedEvent,
}

// Deliberately bounded, process-local startup buffering, not a durable inbox.
// Never log URL contents: a deep link may contain credentials or personal data.
internal class ApplicationActivation on thread.main {
  readonly reopenRequested: Event<ApplicationReopenRequestedEvent>;
  readonly openURLRequested: Event<ApplicationOpenURLRequestedEvent>;
  readonly secondInstanceLaunched: Event<ApplicationSecondInstanceLaunchedEvent>;
  schemes: Array<String>;
  pending: Map<usize, ActivationRequest>;
  head: usize;
  tail: usize;
  count: usize;
  ready: boolean;
  closed: boolean;
  draining: boolean;

  internal constructor() {
    this.reopenRequested = new Event<ApplicationReopenRequestedEvent>();
    this.openURLRequested = new Event<ApplicationOpenURLRequestedEvent>();
    this.secondInstanceLaunched = new Event<ApplicationSecondInstanceLaunchedEvent>();
    this.schemes = Array<String>();
    this.pending = Map<usize, ActivationRequest>();
    this.head = 0;
    this.tail = 0;
    this.count = 0;
    this.ready = false;
    this.closed = false;
    this.draining = false;
  }

  function configure(inout this, schemes: Array<String>): void {
    if (!this.ready && !this.closed) this.schemes = move schemes;
  }

  function acceptsURL(in url: String): boolean {
    if (url.byteLength == 0 || url.byteLength > 16384) return false;
    let colon: usize = 0;
    while (colon < url.byteLength && url.byteAt(colon) != 58) {
      colon = colon + 1;
    }
    if (colon == 0 || colon == url.byteLength) return false;
    let offset: usize = 0;
    while (offset < url.byteLength) {
      const byte = url.byteAt(offset);
      if (byte <= 32 || byte == 127) return false;
      offset = offset + 1;
    }
    for (const scheme of this.schemes) {
      if (scheme.byteLength != colon) continue;
      let matches = true;
      let index: usize = 0;
      while (index < colon) {
        let byte = url.byteAt(index);
        if (byte >= 65 && byte <= 90) byte = byte + 32;
        if (byte != scheme.byteAt(index)) matches = false;
        index = index + 1;
      }
      if (matches) return true;
    }
    return false;
  }

  function enqueue(inout this, request: ActivationRequest): boolean {
    if (this.closed || this.count == 64) return false;
    this.pending.set(this.tail, move request);
    this.tail = (this.tail + 1) % 64;
    this.count = this.count + 1;
    this.drain();
    return true;
  }

  function requestReopen(inout this): boolean {
    return this.enqueue(ActivationRequest.reopen);
  }

  function requestOpenURL(inout this, url: String): boolean {
    if (!this.acceptsURL(in url)) return false;
    return this.enqueue(ActivationRequest.openURL(move url));
  }

  function start(inout this): void {
    if (this.closed) return;
    this.ready = true;
    this.drain();
  }

  function requestSecondInstance(
    inout this,
    launch: ApplicationSecondInstanceLaunchedEvent
  ): boolean {
    if (!validApplicationLaunch(in launch)) return false;
    return this.enqueue(ActivationRequest.secondInstance(move launch));
  }

  function drain(inout this): void {
    if (!this.ready || this.closed || this.draining) return;
    this.draining = true;
    while (!this.closed && this.count > 0) {
      const selected = this.pending.remove(this.head);
      this.head = (this.head + 1) % 64;
      this.count = this.count - 1;
      match (selected) {
        some(request) => match (request) {
          reopen => {
            const event = ApplicationReopenRequestedEvent();
            let source = this.reopenRequested;
            source.publish(in event);
          }
          openURL(url) => {
            const event = ApplicationOpenURLRequestedEvent({ url });
            let source = this.openURLRequested;
            source.publish(in event);
          }
          secondInstance(event) => {
            let source = this.secondInstanceLaunched;
            source.publish(in event);
          }
        }
        none => {}
      }
    }
    this.draining = false;
  }

  function finish(inout this): void {
    this.closed = true;
    this.ready = false;
    this.pending = Map<usize, ActivationRequest>();
    this.count = 0;
    let reopen = this.reopenRequested;
    let urls = this.openURLRequested;
    let launches = this.secondInstanceLaunched;
    reopen.finish();
    urls.finish();
    launches.finish();
  }
}
