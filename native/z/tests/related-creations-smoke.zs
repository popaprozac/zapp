import { Set } from "std/collections";
import { thread } from "std/thread";
import console from "std/console";
import { CapabilitySelection } from "../framework/application-capabilities.zs";
import { BridgeDocument } from "../framework/bridge-document.zs";
import { RelatedDocuments, RelatedDocumentIdentity, createRelatedDocuments } from "../framework/related-documents.zs";
import { RelatedWindowCreations, RelatedWindowReservation, RelatedCreationCleanup } from "../framework/related-window-creations.zs";

function verify(value: boolean, code: i32): void throws i32 {
  if (!value) { console.error(`creation verification failed: ${code}`); throw code; }
}
function identity(value: Option<RelatedDocumentIdentity>): RelatedDocumentIdentity throws i32 {
  return match (value) { some(value) => value; none => throw 1; };
}
function reserved(value: Option<RelatedWindowReservation>): RelatedWindowReservation throws i32 {
  return match (value) { some(value) => value; none => throw 2; };
}
function endpoint(value: Option<BridgeDocument>): BridgeDocument throws i32 {
  return match (value) { some(value) => value; none => throw 3; };
}
function absent(value: Option<BridgeDocument>): boolean {
  return match (value) { some(value) => false; none => true; };
}
function refused(value: Option<RelatedWindowReservation>): boolean {
  return match (value) { some(value) => false; none => true; };
}

function selection(allowed: boolean): CapabilitySelection {
  let permissions = Set<String>();
  if (allowed) permissions.add("window:create");
  let services = Set<String>();
  services.add("notes.list");
  let names = Array<String>("notes");
  let workers = Set<String>();
  return new CapabilitySelection({ names: names.freeze(),
    permissions: permissions.freeze(), serviceMethods: services.freeze(), workerIds: workers.freeze() });
}

class CleanupProbe on thread.main {
  count: i32;
  observedTerminal: boolean;
  constructor() { this.count = 0; this.observedTerminal = true; }
  function observe(inout this, documents: RelatedDocuments, in reservation: RelatedWindowReservation): void {
    this.count = this.count + 1;
    this.observedTerminal = this.observedTerminal && !documents.isLive(in reservation.child);
  }
  function increment(inout this): void { this.count = this.count + 1; }
}

function makeReady(document: BridgeDocument, in reservation: RelatedWindowReservation): void throws i32 on thread.main {
  document.didCommit();
  const realm = "0123456789abcdef0123456789abcdef";
  const offered = try identity(document.offer(in realm));
  try verify(offered.token == reservation.child.token, 4);
  const token = `${offered.token}`;
  try verify(!document.acknowledge(in token, copy realm), 5);
  try verify(document.observeShell(in token, in realm), 6);
}

function abandon(documents: RelatedDocuments, in owner: RelatedDocumentIdentity): void throws i32 on thread.main {
  const creations = new RelatedWindowCreations(documents);
  const reservation = try reserved(creations.begin(in owner, 99, 0, 10));
  // No callback retains this table: its record's fallback deinit must retire
  // even an unclaimed document when the surrounding owner goes away.
}

function run(): i32 throws i32 on thread.main {
  const documents = createRelatedDocuments();
  const creations = new RelatedWindowCreations(documents);
  const owner = try identity(documents.registerOwner(1, selection(true)));
  const other = try identity(documents.registerOwner(2, selection(true)));
  const denied = try identity(documents.registerOwner(3, selection(false)));
  try abandon(documents, in owner);
  try verify(documents.count() == 3, 7);
  try verify(refused(creations.begin(in denied, 10, 0, 10)), 10);
  try verify(refused(creations.begin(in owner, 10, 10, 10)), 11);
  const request = try reserved(creations.begin(in owner, 10, 0, 10));
  const rejectedAttachments = new CleanupProbe();
  const beforeClaim: RelatedCreationCleanup = move (): void => rejectedAttachments.increment();
  try verify(!creations.attach(in request, beforeClaim, 1) && rejectedAttachments.count == 1, 8);
  try verify(refused(creations.begin(in owner, 10, 0, 10)), 12);
  try verify(absent(creations.claim(in other, in request, 1)), 13);
  const forged = RelatedWindowReservation({ owner: copy owner, child: RelatedDocumentIdentity({ windowId: 10, token: request.child.token + 1 }) });
  try verify(absent(creations.claim(in owner, in forged, 1)), 14);
  const document = try endpoint(creations.claim(in owner, in request, 1));
  try verify(absent(creations.claim(in owner, in request, 1)), 15);
  const probe = new CleanupProbe();
  const cleanup: RelatedCreationCleanup = move (): void => probe.observe(documents, in request);
  try verify(creations.attach(in request, cleanup, 1), 16);
  const duplicate: RelatedCreationCleanup = move (): void => rejectedAttachments.increment();
  try verify(!creations.attach(in request, duplicate, 1) && rejectedAttachments.count == 2, 9);
  try verify(!creations.complete(in request, 1), 17);
  try makeReady(document, in request);
  const authority = match (documents.capabilitiesFor(in request.child)) { some(value) => value; none => throw 18; };
  try verify(authority.allowsService("notes.list") && !authority.allowsService("admin.erase"), 19);
  try verify(creations.complete(in request, 2), 20);
  try verify(!creations.complete(in request, 2) && !creations.fail(in request), 21);
  try verify(probe.count == 0 && creations.count() == 0 && documents.isReady(in request.child), 22);
  document.close();

  // Retire routing and remove the record before invoking potentially reentrant
  // native cleanup. A replay must not repeat cleanup or affect a reused ID.
  const failed = try reserved(creations.begin(in owner, 10, 2, 10));
  const failedDocument = try endpoint(creations.claim(in owner, in failed, 2));
  const reentrant: RelatedCreationCleanup = move (): void => {
    probe.observe(documents, in failed);
    creations.fail(in failed);
  };
  try verify(creations.attach(in failed, reentrant, 2), 23);
  try verify(creations.fail(in failed) && !creations.fail(in failed), 24);
  try verify(probe.count == 1 && probe.observedTerminal, 25);
  const late: RelatedCreationCleanup = move (): void => probe.increment();
  try verify(!creations.attach(in failed, late, 2) && probe.count == 2, 26);
  const reused = try reserved(creations.begin(in owner, 10, 2, 10));
  try verify(reused.child.token != failed.child.token && !creations.fail(in failed), 27);
  try verify(creations.count() == 1 && documents.isLive(in reused.child), 28);
  creations.expire(9);
  try verify(creations.count() == 1, 29);
  creations.expire(10);
  try verify(creations.count() == 0 && !documents.isLive(in reused.child), 30);

  const lost = try reserved(creations.begin(in owner, 11, 10, 20));
  const lostDocument = try endpoint(creations.claim(in owner, in lost, 10));
  const lostCleanup: RelatedCreationCleanup = move (): void => probe.observe(documents, in lost);
  try verify(creations.attach(in lost, lostCleanup, 10), 31);
  const retired = documents.retire(in owner);
  creations.pruneInvalidated();
  try verify(probe.count == 3 && probe.observedTerminal && creations.count() == 0, 32);
  const replacement = try identity(documents.registerOwner(1, selection(true)));
  try verify(absent(creations.claim(in replacement, in lost, 11)), 33);

  // Shutdown cannot be undone by cleanup opening another reservation.
  const final = try reserved(creations.begin(in other, 12, 10, 20));
  const finalDocument = try endpoint(creations.claim(in other, in final, 10));
  const shutdown: RelatedCreationCleanup = move (): void => {
    probe.observe(documents, in final);
    const rejected = creations.begin(in other, 13, 10, 20);
  };
  try verify(creations.attach(in final, shutdown, 10), 34);
  creations.cancelAll();
  creations.cancelAll();
  try verify(probe.count == 4 && creations.count() == 0 && documents.count() == 3, 35);
  try verify(refused(creations.begin(in other, 14, 10, 20)), 36);
  console.log("related creations: one-shot, readiness, rollback, expiry, owner retirement passed");
  return 0;
}

function main(): i32 on thread.main {
  return match (attempt run()) { success(value) => value; failure(code) => code; };
}
