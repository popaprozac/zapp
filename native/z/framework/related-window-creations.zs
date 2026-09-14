import { Map } from "std/collections";
import { thread } from "std/thread";
import { BridgeDocument } from "./bridge-document.zs";
import { RelatedDocuments, RelatedDocumentIdentity } from "./related-documents.zs";

internal type RelatedCreationCleanup = () => void on thread.main;

// Correlation only. Native callbacks must separately validate their actual
// sending WebView/frame/origin. Neither identity chooses a capability profile.
internal readonly struct RelatedWindowReservation {
  owner: RelatedDocumentIdentity;
  child: RelatedDocumentIdentity;
}

function ignoreCleanup(): void on thread.main {}

class CreationRecord on thread.main {
  readonly reservation: RelatedWindowReservation;
  readonly document: BridgeDocument;
  readonly deadline: u64;
  claimed: boolean;
  attached: boolean;
  active: boolean;
  cleanup: RelatedCreationCleanup;

  function claim(inout this): boolean {
    if (!this.active || this.claimed) return false;
    this.claimed = true;
    return true;
  }

  function attach(inout this, cleanup: RelatedCreationCleanup): boolean {
    if (!this.active || !this.claimed || this.attached) return false;
    this.cleanup = cleanup;
    this.attached = true;
    return true;
  }

  function complete(inout this): void { this.active = false; }

  function fail(inout this): void {
    if (!this.active) return;
    this.active = false;
    // Routing is terminal before cleanup can synchronously call back into Z.
    this.document.close();
    this.cleanup();
  }

  deinit {
    if (this.active) {
      this.document.close();
      this.cleanup();
    }
  }
}

// Owned by the native window registry. Deadline values are monotonic ticks
// supplied by the platform; tests use deterministic ticks, not wall-clock sleeps.
// No ordinary service request pays for this table or its cleanup closure.
internal class RelatedWindowCreations on thread.main {
  private readonly documents: RelatedDocuments;
  private records: Map<i32, CreationRecord>;
  private closed: boolean;

  internal constructor(documents: RelatedDocuments) {
    this.documents = documents;
    this.records = Map<i32, CreationRecord>();
    this.closed = false;
  }

  function count(): usize { return this.records.length; }

  function begin(
    inout this,
    in owner: RelatedDocumentIdentity,
    windowId: i32,
    now: u64,
    deadline: u64
  ): Option<RelatedWindowReservation> {
    if (this.closed || deadline <= now || this.records.has(windowId)) return Option.none;
    const authority = match (this.documents.capabilitiesFor(in owner)) {
      some(value) => value;
      none => return Option.none;
    };
    if (!authority.allowsPermission("window:create")) return Option.none;
    const document = match (BridgeDocument.beginRelated(windowId, this.documents, in owner)) {
      some(value) => value;
      none => return Option.none;
    };
    const child = match (document.creationIdentity()) {
      some(value) => value;
      none => { document.close(); return Option.none; }
    };
    const reservation = RelatedWindowReservation({ owner: copy owner, child });
    this.records.set(windowId, new CreationRecord({ reservation: copy reservation, document, deadline,
      claimed: false, attached: false, active: true, cleanup: ignoreCleanup }));
    return Option.some(reservation);
  }

  private function lookup(in reservation: RelatedWindowReservation): Option<CreationRecord> {
    const found = this.records.get(reservation.child.windowId);
    return match (in found) {
      some(record) => {
        const expected = record.reservation;
        if (expected.child.token != reservation.child.token
          || expected.owner.windowId != reservation.owner.windowId
          || expected.owner.token != reservation.owner.token) return Option.none;
        const retained: CreationRecord = record;
        select Option.some(retained);
      }
      none => Option.none;
    };
  }

  private function valid(record: CreationRecord, now: u64): boolean {
    return now < record.deadline && this.documents.isReady(in record.reservation.owner)
      && this.documents.isLive(in record.reservation.child);
  }

  function claim(
    inout this,
    in owner: RelatedDocumentIdentity,
    in reservation: RelatedWindowReservation,
    now: u64
  ): Option<BridgeDocument> {
    // A different owner must not consume another document's pending request.
    if (owner.windowId != reservation.owner.windowId || owner.token != reservation.owner.token) return Option.none;
    const record = match (this.lookup(in reservation)) { some(value) => value; none => return Option.none; };
    if (!this.valid(record, now)) { this.fail(in reservation); return Option.none; }
    if (!record.claim()) return Option.none;
    return Option.some(record.document);
  }

  // Install immediately after native allocation. A late attachment cleans up
  // its own resources instead of leaving a window/registration orphan behind.
  function attach(
    inout this,
    in reservation: RelatedWindowReservation,
    cleanup: RelatedCreationCleanup,
    now: u64
  ): boolean {
    const record = match (this.lookup(in reservation)) {
      some(value) => value;
      none => { cleanup(); return false; }
    };
    if (!this.valid(record, now)) {
      this.fail(in reservation);
      cleanup();
      return false;
    }
    if (record.attach(cleanup)) return true;
    cleanup();
    return false;
  }

  // The platform already owns the completed native runtime before this call.
  // Dropping the rollback closure transfers responsibility, not resources.
  function complete(inout this, in reservation: RelatedWindowReservation, now: u64): boolean {
    const record = match (this.lookup(in reservation)) { some(value) => value; none => return false; };
    if (!this.valid(record, now)) { this.fail(in reservation); return false; }
    if (!record.claimed || !record.attached || !record.document.isCurrent(in reservation.child)) return false;
    record.complete();
    this.records.delete(reservation.child.windowId);
    return true;
  }

  function fail(inout this, in reservation: RelatedWindowReservation): boolean {
    const record = match (this.lookup(in reservation)) { some(value) => value; none => return false; };
    this.records.delete(reservation.child.windowId);
    record.fail();
    return true;
  }

  function pruneInvalidated(inout this): void {
    let stale = Array<RelatedWindowReservation>();
    for (const entry of this.records) {
      const reservation = entry.value.reservation;
      if (!this.documents.isReady(in reservation.owner) || !this.documents.isLive(in reservation.child)) stale.push(copy reservation);
    }
    for (const reservation of stale) { this.fail(in reservation); }
  }

  function expire(inout this, now: u64): void {
    let expired = Array<RelatedWindowReservation>();
    for (const entry of this.records) {
      if (!this.valid(entry.value, now)) expired.push(copy entry.value.reservation);
    }
    for (const reservation of expired) { this.fail(in reservation); }
  }

  function cancelAll(inout this): void {
    // Application shutdown is terminal, including reentrant cleanup callbacks.
    this.closed = true;
    let pending = Array<RelatedWindowReservation>();
    for (const entry of this.records) { pending.push(copy entry.value.reservation); }
    for (const reservation of pending) { this.fail(in reservation); }
  }
}
