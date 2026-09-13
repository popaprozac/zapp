import { Map } from "std/collections";
import { TaskControl } from "std/async";
import { thread } from "std/thread";
import { CapabilitySelection } from "./application-capabilities.zs";
import { PendingRequests, createPendingRequests } from "./pending-requests.zs";

// Native-minted correlation identity, not a renderer-supplied permission token.
// One registry belongs to one application runtime and is never reset in place.
internal readonly struct RelatedDocumentIdentity {
  windowId: i32;
  token: u64;
}

internal readonly struct RelatedDocumentRequest {
  document: RelatedDocumentIdentity;
  id: u64;
  generation: u64;
}

class RelatedDocumentRecord on thread.main {
  readonly identity: RelatedDocumentIdentity;
  readonly owner: Option<RelatedDocumentIdentity>;
  readonly capabilities: CapabilitySelection;
  readonly requests: PendingRequests;
  bridgeReady: boolean;
  documentReady: boolean;

  function ready(): boolean {
    return this.bridgeReady && this.documentReady;
  }

  function observeBridge(inout this): void { this.bridgeReady = true; }
  function observeDocument(inout this): void { this.documentReady = true; }
}

// Platform-neutral bookkeeping, confined to the current main-executor tier.
// Callers must validate the actual sending WebView/frame/origin before marking
// readiness or routing. This registry alone does not authenticate native input.
internal class RelatedDocuments on thread.main {
  private records: Map<i32, RelatedDocumentRecord>;
  private nextToken: u64;

  internal constructor() {
    this.records = Map<i32, RelatedDocumentRecord>();
    this.nextToken = 1;
  }

  function count(): usize { return this.records.length; }

  private function lookup(in identity: RelatedDocumentIdentity): Option<RelatedDocumentRecord> {
    const found = this.records.get(identity.windowId);
    return match (in found) {
      some(record) => {
        if (record.identity.token == identity.token) {
          const retained: RelatedDocumentRecord = record;
          return Option.some(retained);
        }
        select Option.none;
      }
      none => Option.none;
    };
  }

  function isLive(in identity: RelatedDocumentIdentity): boolean {
    return match (this.lookup(in identity)) { some(record) => record.identity.token == identity.token; none => false; };
  }

  function isReady(in identity: RelatedDocumentIdentity): boolean {
    return match (this.lookup(in identity)) { some(record) => record.ready(); none => false; };
  }

  // Ordinary owner authority is already validated by native WindowOptions.
  // Related creation has deliberately no capability/profile argument.
  function registerOwner(
    inout this,
    windowId: i32,
    capabilities: CapabilitySelection
  ): Option<RelatedDocumentIdentity> {
    return this.insert(windowId, Option<RelatedDocumentIdentity>.none, capabilities, true);
  }

  // Native WebViews begin unroutable until the document-bound handshake is
  // acknowledged. Headless/native callers may still register a proven owner.
  function beginOwner(
    inout this,
    windowId: i32,
    capabilities: CapabilitySelection
  ): Option<RelatedDocumentIdentity> {
    return this.insert(windowId, Option<RelatedDocumentIdentity>.none, capabilities, false);
  }

  function beginRelated(
    inout this,
    in owner: RelatedDocumentIdentity,
    windowId: i32
  ): Option<RelatedDocumentIdentity> {
    const found = this.lookup(in owner);
    return match (found) {
      some(record) => {
        if (!record.ready()) return Option<RelatedDocumentIdentity>.none;
        select this.insert(windowId, Option.some(copy owner), record.capabilities, false);
      }
      none => Option.none;
    };
  }

  private function insert(
    inout this,
    windowId: i32,
    owner: Option<RelatedDocumentIdentity>,
    capabilities: CapabilitySelection,
    ready: boolean
  ): Option<RelatedDocumentIdentity> {
    if (windowId <= 0 || this.records.has(windowId) || this.nextToken == 0) return Option.none;
    const identity = RelatedDocumentIdentity({ windowId, token: this.nextToken });
    // Fail closed at exhaustion; never wrap and reuse a stale document token.
    if (this.nextToken == 18446744073709551615) this.nextToken = 0;
    else this.nextToken = this.nextToken + 1;
    this.records.set(windowId, new RelatedDocumentRecord({
      identity: copy identity,
      owner,
      capabilities,
      requests: createPendingRequests(),
      bridgeReady: ready,
      documentReady: ready,
    }));
    return Option.some(identity);
  }

  function observeBridge(in identity: RelatedDocumentIdentity): boolean {
    return match (this.lookup(in identity)) {
      some(record) => { record.observeBridge(); select record.ready(); }
      none => false;
    };
  }

  function observeDocument(in identity: RelatedDocumentIdentity): boolean {
    return match (this.lookup(in identity)) {
      some(record) => { record.observeDocument(); select record.ready(); }
      none => false;
    };
  }

  function capabilitiesFor(in identity: RelatedDocumentIdentity): Option<CapabilitySelection> {
    return match (this.lookup(in identity)) {
      some(record) => {
        if (!record.ready()) return Option<CapabilitySelection>.none;
        select Option.some(record.capabilities);
      }
      none => Option.none;
    };
  }

  function beginRequest(in identity: RelatedDocumentIdentity, id: u64): Option<RelatedDocumentRequest> {
    return match (this.lookup(in identity)) {
      some(record) => {
        if (!record.ready()) return Option<RelatedDocumentRequest>.none;
        const generation = record.requests.begin(id);
        select Option.some(RelatedDocumentRequest({ document: copy identity, id, generation }));
      }
      none => Option.none;
    };
  }

  function attachRequest(in request: RelatedDocumentRequest, control: TaskControl): boolean {
    return match (this.lookup(in request.document)) {
      some(record) => record.requests.attachGeneration(request.id, request.generation, control);
      none => { control.requestCancel(); select false; }
    };
  }

  // Consume completion before delivering a reply. False means stale, cancelled,
  // duplicate, or retired: the platform must not evaluate JS for that reply.
  function finishRequest(in request: RelatedDocumentRequest): boolean {
    return match (this.lookup(in request.document)) {
      some(record) => record.requests.finishIfCurrent(request.id, request.generation);
      none => false;
    };
  }

  function cancelRequest(in identity: RelatedDocumentIdentity, id: u64): boolean {
    return match (this.lookup(in identity)) {
      some(record) => record.requests.cancel(id);
      none => false;
    };
  }

  private function descendsFrom(record: RelatedDocumentRecord, in ancestor: RelatedDocumentIdentity): boolean {
    let current = record;
    let remaining = this.records.length;
    while (remaining > 0) {
      remaining = remaining - 1;
      if (current.identity.token == ancestor.token && current.identity.windowId == ancestor.windowId) return true;
      const parent = match (in current.owner) {
        some(identity) => this.lookup(in identity);
        none => return false;
      };
      match (parent) { some(value) => current = value; none => return false; }
    }
    return false;
  }

  // Committed retirement only: the window manager must finish cancellable
  // family preflight BEFORE calling this. No JS/native close callback is run
  // here. Remove every descendant before requesting any task cancellation.
  function retire(inout this, in identity: RelatedDocumentIdentity): Array<RelatedDocumentIdentity> {
    let retired = Array<RelatedDocumentIdentity>();
    if (!this.isLive(in identity)) return retired;
    for (const entry of this.records) {
      if (this.descendsFrom(entry.value, in identity)) retired.push(copy entry.value.identity);
    }
    let requests = Array<PendingRequests>();
    for (const document of retired) {
      match (this.records.remove(document.windowId)) {
        some(record) => requests.push(record.requests);
        none => {}
      }
    }
    for (const pending of requests) {
      let owned: PendingRequests = pending;
      owned.cancelAll();
    }
    return retired;
  }
}

internal function createRelatedDocuments(): RelatedDocuments on thread.main {
  return new RelatedDocuments();
}
