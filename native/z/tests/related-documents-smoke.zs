import { Set } from "std/collections";
import { TaskScope, TaskControl } from "std/async";
import { Mutex } from "std/sync";
import { thread } from "std/thread";
import { delay } from "std/time";
import console from "std/console";
import { CapabilitySelection } from "../framework/application-capabilities.zs";
import { BridgeDocument } from "../framework/bridge-document.zs";
import {
  RelatedDocuments,
  RelatedDocumentIdentity,
  RelatedDocumentRequest,
  createRelatedDocuments,
} from "../framework/related-documents.zs";

function verify(value: boolean, code: i32): void throws i32 {
  if (!value) { console.error(`verification failed: ${code}`); throw code; }
}

function document(value: Option<RelatedDocumentIdentity>): RelatedDocumentIdentity throws i32 {
  return match (value) { some(identity) => identity; none => throw 1; };
}

function request(value: Option<RelatedDocumentRequest>): RelatedDocumentRequest throws i32 {
  return match (value) { some(ticket) => ticket; none => throw 2; };
}

function selection(): CapabilitySelection {
  let names = Array<String>("notes");
  let permissions = Set<String>();
  permissions.add("window.create");
  let services = Set<String>();
  services.add("notes.list");
  let workers = Set<String>();
  workers.add("indexer");
  return new CapabilitySelection({
    names: names.freeze(),
    permissions: permissions.freeze(),
    serviceMethods: services.freeze(),
    workerIds: workers.freeze(),
  });
}

function ready(registry: RelatedDocuments, in identity: RelatedDocumentIdentity): void throws i32 on thread.main {
  try verify(!registry.observeDocument(in identity), 3);
  try verify(registry.observeBridge(in identity), 4);
}

function retireCount(registry: RelatedDocuments, in identity: RelatedDocumentIdentity): usize on thread.main {
  const retired = registry.retire(in identity);
  return retired.length;
}

function checkIdentities(): void throws i32 on thread.main {
  const registry = createRelatedDocuments();
  const owner = try document(registry.registerOwner(1, selection()));
  const other = try document(registry.registerOwner(2, selection()));
  try verify(registry.count() == 2, 10);
  const duplicateRefused = match (registry.registerOwner(1, selection())) { some(value) => false; none => true; };
  try verify(duplicateRefused, 11);
  const child = try document(registry.beginRelated(in owner, 3));
  try verify(!registry.isReady(in child), 12);
  const unreadyChildRefused = match (registry.beginRelated(in child, 4)) { some(value) => false; none => true; };
  const unreadyAuthorityRefused = match (registry.capabilitiesFor(in child)) { some(value) => false; none => true; };
  const unreadyRequestRefused = match (registry.beginRequest(in child, 1)) { some(value) => false; none => true; };
  try verify(unreadyChildRefused, 13);
  try verify(unreadyAuthorityRefused, 14);
  try verify(unreadyRequestRefused, 15);
  const wrong = RelatedDocumentIdentity({ windowId: child.windowId, token: other.token });
  try verify(!registry.observeBridge(in wrong), 16);
  try verify(!registry.observeBridge(in child), 17);
  try verify(registry.observeDocument(in child), 18);
  try verify(registry.isReady(in child), 19);
  const inherited = match (registry.capabilitiesFor(in child)) {
    some(value) => value;
    none => throw 20;
  };
  try verify(inherited.allowsPermission("window.create"), 21);
  try verify(!inherited.allowsPermission("shell.open"), 22);
  try verify(inherited.allowsService("notes.list"), 23);
  try verify(!inherited.allowsService("notes.delete"), 24);
  try verify(inherited.allowsWorker("indexer"), 25);
  try verify(!inherited.allowsWorker("admin"), 26);
  const grandchild = try document(registry.beginRelated(in child, 4));
  try ready(registry, in grandchild);
  const sibling = try document(registry.beginRelated(in owner, 5));
  try ready(registry, in sibling);
  // Partial construction belongs to the owner too, even before readiness.
  const preparing = try document(registry.beginRelated(in child, 6));
  const held = try request(registry.beginRequest(in child, 42));
  try verify(retireCount(registry, in wrong) == 0, 27);
  try verify(retireCount(registry, in child) == 3, 28);
  try verify(!registry.isLive(in grandchild) && !registry.isLive(in preparing), 29);
  try verify(!registry.observeDocument(in preparing) && !registry.observeBridge(in preparing), 30);
  try verify(registry.isReady(in owner) && registry.isReady(in sibling) && registry.isReady(in other), 31);
  try verify(!registry.finishRequest(in held), 32);
  try verify(retireCount(registry, in child) == 0, 33);

  const replacement = try document(registry.beginRelated(in owner, 3));
  try ready(registry, in replacement);
  try verify(replacement.token != child.token, 34);
  const fresh = try request(registry.beginRequest(in replacement, 42));
  try verify(!registry.finishRequest(in held), 35);
  try verify(!registry.cancelRequest(in child, 42), 36);
  try verify(retireCount(registry, in child) == 0, 37);
  try verify(registry.finishRequest(in fresh), 38);
  try verify(!registry.finishRequest(in fresh), 39);
  const oldRequest = try request(registry.beginRequest(in sibling, 7));
  const newRequest = try request(registry.beginRequest(in sibling, 7));
  try verify(!registry.finishRequest(in oldRequest), 40);
  try verify(registry.finishRequest(in newRequest), 41);
  try verify(retireCount(registry, in owner) == 3, 42);
  try verify(registry.isReady(in other) && registry.count() == 1, 43);
  const retiredOwnerRefused = match (registry.beginRelated(in owner, 8)) { some(value) => false; none => true; };
  try verify(retiredOwnerRefused, 44);
  const newOwner = try document(registry.registerOwner(1, selection()));
  try verify(newOwner.token != owner.token, 45);
  try verify(retireCount(registry, in owner) == 0 && registry.isReady(in newOwner), 46);
  retireCount(registry, in newOwner);
  retireCount(registry, in other);
  try verify(registry.count() == 0, 47);
}

struct WorkState {
  started: i32;
  completed: i32;
}

readonly class WorkProbe {
  readonly state: Mutex<WorkState>;

  function start(): void {
    this.state.withLock((inout state): void => { state.started = state.started + 1; });
  }
  function complete(): void {
    this.state.withLock((inout state): void => { state.completed = state.completed + 1; });
  }
  function started(): i32 { return this.state.withLock((in state): i32 => state.started); }
  function completed(): i32 { return this.state.withLock((in state): i32 => state.completed); }
}

function probe(): WorkProbe {
  return new WorkProbe({ state: Mutex(WorkState({ started: 0, completed: 0 })) });
}

async function slowWork(probe: WorkProbe): void on thread.main {
  probe.start();
  await delay(1000);
  probe.complete();
}

async function shortWork(probe: WorkProbe): void on thread.main {
  probe.start();
  await delay(20);
  probe.complete();
}

function scheduleSlowWork(updates: TaskScope, probe: WorkProbe): TaskControl on thread.main {
  return updates.schedule(thread.main, async move (): void => await slowWork(probe));
}

function scheduleShortWork(updates: TaskScope, probe: WorkProbe): TaskControl on thread.main {
  return updates.schedule(thread.main, async move (): void => await shortWork(probe));
}

async function retireRunningChild(
  registry: RelatedDocuments,
  child: RelatedDocumentIdentity,
  ticket: RelatedDocumentRequest,
  lateControl: TaskControl,
  cancelled: WorkProbe,
  surviving: WorkProbe,
  retirement: WorkProbe
): void on thread.main {
  await delay(5);
  if (cancelled.started() == 2 && surviving.started() >= 2) retirement.start();
  const retired = registry.retire(in child);
  if (retired.length == 2) retirement.complete();
  // Submission succeeded before retirement, but attachment arrives afterward.
  if (registry.attachRequest(in ticket, lateControl)) retirement.complete();
}

async function checkCancellation(): void throws i32 on thread.main {
  const registry = createRelatedDocuments();
  const owner = try document(registry.registerOwner(1, selection()));
  const child = try document(registry.beginRelated(in owner, 2));
  try ready(registry, in child);
  const sibling = try document(registry.beginRelated(in owner, 3));
  try ready(registry, in sibling);
  const grandchild = try document(registry.beginRelated(in child, 4));
  try ready(registry, in grandchild);
  const updates = new TaskScope();
  const cancelled = probe();
  const surviving = probe();
  const late = probe();
  const retirement = probe();
  const ownerRequest = try request(registry.beginRequest(in owner, 1));
  const siblingRequest = try request(registry.beginRequest(in sibling, 1));
  const childRequest = try request(registry.beginRequest(in child, 1));
  const nestedRequest = try request(registry.beginRequest(in grandchild, 1));
  try verify(registry.attachRequest(in ownerRequest, scheduleShortWork(updates, surviving)), 50);
  try verify(registry.attachRequest(in siblingRequest, scheduleShortWork(updates, surviving)), 51);
  try verify(registry.attachRequest(in childRequest, scheduleSlowWork(updates, cancelled)), 52);
  try verify(registry.attachRequest(in nestedRequest, scheduleSlowWork(updates, cancelled)), 53);
  const lateControl = scheduleSlowWork(updates, late);
  try verify(lateControl.accepted, 54);
  // Wait one timer turn for taskification wrappers to enter the operations;
  // retireRunningChild verifies they actually started before cancellation.
  const retirementControl = updates.schedule(thread.main, async move (): void => await retireRunningChild(
    registry, child, childRequest, lateControl, cancelled, surviving, retirement
  ));
  try verify(retirementControl.accepted, 55);
  const oldRequest = try request(registry.beginRequest(in sibling, 2));
  const newRequest = try request(registry.beginRequest(in sibling, 2));
  try verify(!registry.attachRequest(in oldRequest, scheduleSlowWork(updates, late)), 57);
  try verify(registry.attachRequest(in newRequest, scheduleShortWork(updates, surviving)), 58);
  await updates.close();
  try verify(retirement.started() == 1 && retirement.completed() == 1, 56);
  try verify(cancelled.completed() == 0 && late.completed() == 0, 59);
  try verify(surviving.completed() == 3, 60);
  try verify(!registry.finishRequest(in childRequest) && !registry.finishRequest(in nestedRequest), 61);
  try verify(registry.finishRequest(in ownerRequest) && registry.finishRequest(in siblingRequest), 62);
  try verify(!registry.finishRequest(in oldRequest) && registry.finishRequest(in newRequest), 63);
  retireCount(registry, in owner);
  try verify(registry.count() == 0, 64);
}

function checkDocumentEndpoint(): void throws i32 on thread.main {
  const registry = createRelatedDocuments();
  const endpoint = new BridgeDocument(10, registry, selection());
  const realm = "0123456789abcdef0123456789abcdef";
  const beforeCommit = match (endpoint.offer(in realm)) { some(value) => true; none => false; };
  try verify(!beforeCommit, 70);
  endpoint.didCommit();
  const first = try document(endpoint.offer(in realm));
  const firstToken = `${first.token}`;
  try verify(!endpoint.isCurrent(in first), 71);
  try verify(!endpoint.acknowledge("0", copy realm), 72);
  try verify(endpoint.acknowledge(in firstToken, copy realm), 73);
  try verify(endpoint.isCurrent(in first), 74);
  const firstRequest = try request(registry.beginRequest(in first, 1));
  endpoint.didCommit();
  const second = try document(endpoint.offer(in realm));
  const secondToken = `${second.token}`;
  try verify(second.token > first.token, 75);
  try verify(!endpoint.acknowledge(in firstToken, copy realm), 76);
  try verify(!registry.finishRequest(in firstRequest), 77);
  try verify(endpoint.acknowledge(in secondToken, copy realm), 78);
  const wrongRealm = "fedcba9876543210fedcba9876543210";
  const refused = match (endpoint.offer(in wrongRealm)) { some(value) => false; none => true; };
  try verify(refused && !endpoint.acknowledge(in secondToken, copy wrongRealm), 79);
  try verify(!endpoint.isCurrent(in first) && endpoint.isCurrent(in second), 80);
  endpoint.retire();
  try verify(!endpoint.isCurrent(in second) && registry.count() == 0, 81);
  endpoint.close();
  endpoint.didCommit();
  const afterClose = match (endpoint.offer(in realm)) { some(value) => true; none => false; };
  try verify(!afterClose, 82);
}

function relatedEndpoint(value: Option<BridgeDocument>): BridgeDocument throws i32 {
  return match (value) { some(endpoint) => endpoint; none => throw 90; };
}

function checkRelatedEndpoint(): void throws i32 on thread.main {
  const registry = createRelatedDocuments();
  const owner = try document(registry.beginOwner(1, selection()));
  const refused = match (BridgeDocument.beginRelated(2, registry, in owner)) {
    some(endpoint) => false;
    none => true;
  };
  try verify(refused && registry.count() == 1, 91);
  try ready(registry, in owner);
  const child = try relatedEndpoint(BridgeDocument.beginRelated(2, registry, in owner));
  const realm = "0123456789abcdef0123456789abcdef";
  const wrongRealm = "fedcba9876543210fedcba9876543210";
  const beforeCommit = match (child.offer(in realm)) { some(value) => true; none => false; };
  try verify(child.requiresShell() && !beforeCommit, 92);
  child.didCommit();
  const identity = try document(child.offer(in realm));
  const token = `${identity.token}`;
  try verify(!child.observeShell(in token, in realm), 93);
  try verify(!child.acknowledge(in token, copy realm), 94);
  try verify(child.bindingMatches(in token, in realm) && !child.isCurrent(in identity), 95);
  const earlyRequest = match (registry.beginRequest(in identity, 1)) { some(value) => true; none => false; };
  try verify(!earlyRequest, 96);
  try verify(!child.observeShell("0", in realm) && !child.observeShell(in token, in wrongRealm), 97);
  try verify(child.observeShell(in token, in realm) && child.isCurrent(in identity), 98);
  const capabilities = match (registry.capabilitiesFor(in identity)) { some(value) => value; none => throw 99; };
  try verify(capabilities.allowsService("notes.list") && !capabilities.allowsService("notes.delete"), 100);

  // A child handle never retargets, even when the native window survives.
  child.didCommit();
  const replacement = match (child.offer(in realm)) { some(value) => true; none => false; };
  try verify(!replacement && !child.isCurrent(in identity) && registry.count() == 1, 101);
  const preparing = try relatedEndpoint(BridgeDocument.beginRelated(3, registry, in owner));
  preparing.close();
  try verify(registry.count() == 1, 102);

  // Native creation/readiness can race owner retirement. Neither a late DOM
  // observation nor another commit may resurrect the child's reserved token.
  const lost = try relatedEndpoint(BridgeDocument.beginRelated(4, registry, in owner));
  lost.didCommit();
  const lostIdentity = try document(lost.offer(in realm));
  const lostToken = `${lostIdentity.token}`;
  lost.acknowledge(in lostToken, copy realm);
  try verify(retireCount(registry, in owner) == 2, 103);
  try verify(!lost.observeShell(in lostToken, in realm), 104);
  lost.didCommit();
  const revived = match (lost.offer(in realm)) { some(value) => true; none => false; };
  try verify(!revived && registry.count() == 0, 105);
}

async function main(): i32 throws i32 on thread.main {
  try checkIdentities();
  try checkDocumentEndpoint();
  try checkRelatedEndpoint();
  try await checkCancellation();
  console.log("related document registry: identity, readiness, authority, generations, cancellation passed");
  return 0;
}
