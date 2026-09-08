import { thread } from "std/thread";
import { Event } from "./events.zs";
import {
  ApplicationSecondInstanceLaunchedEvent,
} from "./application-launch.zs";
import {
  ActivationRequest,
  ActivationInbox,
} from "./activation-inbox.zs";

export readonly struct ApplicationReopenRequestedEvent {}

export readonly struct ApplicationOpenURLRequestedEvent {
  url: String;
}

// Deliberately bounded, process-local startup buffering, not a durable inbox.
// Never log URL contents: a deep link may contain credentials or personal data.
internal class ApplicationActivation on thread.main {
  readonly reopenRequested: Event<ApplicationReopenRequestedEvent>;
  readonly openURLRequested: Event<ApplicationOpenURLRequestedEvent>;
  readonly secondInstanceLaunched: Event<ApplicationSecondInstanceLaunchedEvent>;
  schemes: Array<String>;
  readonly inbox: ActivationInbox;
  ready: boolean;
  draining: boolean;

  internal constructor() {
    this.reopenRequested = new Event<ApplicationReopenRequestedEvent>();
    this.openURLRequested = new Event<ApplicationOpenURLRequestedEvent>();
    this.secondInstanceLaunched = new Event<ApplicationSecondInstanceLaunchedEvent>();
    this.schemes = Array<String>();
    this.inbox = new ActivationInbox();
    this.ready = false;
    this.draining = false;
  }

  function configure(inout this, schemes: Array<String>): void {
    if (!this.ready && !this.inbox.isClosed()) this.schemes = move schemes;
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
    if (!this.inbox.enqueue(move request)) return false;
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
    if (this.inbox.isClosed()) return;
    this.ready = true;
    this.drain();
  }

  function requestSecondInstance(
    inout this,
    launch: ApplicationSecondInstanceLaunchedEvent
  ): boolean {
    if (!this.inbox.admit(move launch)) return false;
    this.drain();
    return true;
  }

  function drain(inout this): void {
    if (!this.ready || this.draining) return;
    this.draining = true;
    while (true) {
      const selected = this.inbox.take();
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
        none => break;
      }
    }
    this.draining = false;
  }

  function finish(inout this): void {
    this.inbox.close();
    this.ready = false;
    let reopen = this.reopenRequested;
    let urls = this.openURLRequested;
    let launches = this.secondInstanceLaunched;
    reopen.finish();
    urls.finish();
    launches.finish();
  }
}
