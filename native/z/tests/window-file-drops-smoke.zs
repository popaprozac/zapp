import { Set } from "std/collections";
import { thread } from "std/thread";
import { ApplicationPaths } from "../api/zapp/service.zs";
import { FilesystemAuthorityBackend, FilesystemAuthorityError, FilesystemAuthority, createFilesystemAuthority } from "../framework/filesystem-authority.zs";
import { CapabilitySelection } from "../framework/application-capabilities.zs";
import { createRelatedDocuments } from "../framework/related-documents.zs";
import { BridgeDocument } from "../framework/bridge-document.zs";
import { WindowFileDrops } from "../framework/window-file-drops.zs";
import { WindowFileDropRequestedEvent, WindowFilesDroppedEvent, WindowDropPosition, EventSubscriptionError,
  WindowFileDragEnteredEvent, WindowFileDragMovedEvent, WindowFileDragEndedEvent } from "../framework/events.zs";
import { createWindowEvents } from "../framework/window-events.zs";

function canonical(in source: String, in paths: ApplicationPaths): Option<String> throws FilesystemAuthorityError on thread.main {
  return source == "/invalid" ? Option.none : Option.some(copy source);
}
function contains(in path: String, in root: String): boolean on thread.main { return path == root; }
function granted(in authority: FilesystemAuthority, in path: String): boolean on thread.main {
  return match (attempt authority.authorize(in path)) { success(_) => true; failure(_) => false; };
}
function ready(inout document: BridgeDocument): boolean on thread.main {
  document.didCommit();
  const identity = match (document.offer("drop-realm")) { some(value) => value; none => return false; };
  const token = `${identity.token}`;
  return document.acknowledge(in token, "drop-realm");
}
class Observation on thread.main {
  accepted: i32; entered: i32; moved: i32; ended: i32;
  constructor() { this.accepted = 0; this.entered = 0; this.moved = 0; this.ended = 0; }
}

function check(): i32 throws EventSubscriptionError on thread.main {
  const paths = ApplicationPaths({ executable: "/app/zapp", resources: "/app/resources", data: "/app/data", config: "/app/config", cache: "/app/cache" });
  let authority = createFilesystemAuthority(in paths);
  authority.start(FilesystemAuthorityBackend({ canonicalize: canonical, contains }));
  let names = Array<String>(); let permissions = Set<String>(); let services = Set<String>(); let workers = Set<String>();
  const selection = new CapabilitySelection({ names: names.freeze(), permissions: permissions.freeze(), serviceMethods: services.freeze(), workerIds: workers.freeze() });
  let document = new BridgeDocument(1, createRelatedDocuments(), selection);
  if (!ready(inout document)) return 1;
  const events = createWindowEvents();
  let drops = new WindowFileDrops("win-1", true, document, authority, events);
  const position = WindowDropPosition({ x: 12.5, y: 30 });
  const observed = new Observation();
  const entered = try events.fileDragEntered.subscribe(move (in event: WindowFileDragEnteredEvent): void => {
    observed.entered = observed.entered + 1;
  });
  const moved = try events.fileDragMoved.subscribe(move (in event: WindowFileDragMovedEvent): void => {
    observed.moved = observed.moved + 1;
  });
  const ended = try events.fileDragEnded.subscribe(move (in event: WindowFileDragEndedEvent): void => {
    observed.ended = observed.ended + 1;
  });
  const accepted = try events.filesDropped.subscribe(move (in event: WindowFilesDroppedEvent): void => {
    observed.accepted = observed.accepted + 1;
  });
  let disabled = new WindowFileDrops("win-1", false, document, authority, events);
  if (disabled.begin(1, position) || observed.entered != 0) return 2;
  if (!drops.begin(1, position)) return 24;
  let index: i32 = 1;
  while (index <= 100) {
    if (!drops.update(1, WindowDropPosition({ x: f64(index), y: 30 }))) return 25;
    index = index + 1;
  }
  if (observed.moved != 0 || !drops.hasMovement()) return 26;
  const movement = match (drops.takeMovement()) { some(value) => value; none => return 27; };
  if (movement.position.x != 100 || observed.moved != 1 || drops.hasMovement()) return 28;
  if (!drops.update(1, WindowDropPosition({ x: 100, y: 30 })) || drops.hasMovement()) return 29;
  if (!drops.update(1, WindowDropPosition({ x: 101, y: 30 }))) return 30;
  drops.clear(); drops.clear();
  match (drops.takeMovement()) { some(_) => return 31; none => {} }
  if (observed.ended != 1 || observed.moved != 1) return 32;
  if (granted(in authority, "/selected/first.txt")) return 33;
  if (!drops.begin(8, position) || !drops.update(8, WindowDropPosition({ x: 102, y: 30 }))) return 35;
  document.didCommit();
  match (drops.takeMovement()) { some(_) => return 36; none => {} }
  if (observed.moved != 1 || observed.entered != observed.ended) return 37;
  if (!ready(inout document)) return 38;
  if (!drops.begin(2, position)) return 3;
  const invalid = Array<String>("/selected/first.txt", "/invalid");
  match (drops.accept(2, in invalid, position)) { some(_) => return 4; none => {} }
  if (granted(in authority, "/selected/first.txt")) return 5;
  const files = Array<String>("/selected/first.txt", "/selected/second.txt");
  const cancellation = try events.fileDropRequested.subscribe((in event: WindowFileDropRequestedEvent): void => event.cancel());
  if (!drops.begin(3, position)) return 6;
  match (drops.accept(3, in files, position)) { some(_) => return 7; none => {} }
  cancellation.unsubscribe();
  if (granted(in authority, "/selected/first.txt")) return 8;
  const endpoint = document;
  const replacing = try events.fileDropRequested.subscribe(move (in event: WindowFileDropRequestedEvent): void => endpoint.didCommit());
  if (!drops.begin(4, position)) return 9;
  match (drops.accept(4, in files, position)) { some(_) => return 10; none => {} }
  replacing.unsubscribe();
  if (granted(in authority, "/selected/second.txt")) return 11;
  if (!ready(inout document) || !drops.begin(5, position)) return 12;
  match (drops.accept(99, in files, position)) { some(_) => return 13; none => {} }
  if (!drops.begin(6, position)) return 14;
  const event = match (drops.accept(6, in files, position)) { some(value) => value; none => return 15; };
  if (event.paths.length != 2 || event.position.x != 12.5 || observed.accepted != 1) return 16;
  if (!granted(in authority, "/selected/first.txt") || !granted(in authority, "/selected/second.txt")) return 17;
  if (granted(in authority, "/selected/first.txt/child") || granted(in authority, "/selected/neighbor.txt")) return 18;
  match (drops.accept(6, in files, position)) { some(_) => return 19; none => {} }
  authority.stop();
  authority.start(FilesystemAuthorityBackend({ canonicalize: canonical, contains }));
  if (granted(in authority, "/selected/first.txt")) return 20;
  const closing = try events.fileDropRequested.subscribe(move (in event: WindowFileDropRequestedEvent): void => endpoint.close());
  if (!drops.begin(7, position)) return 21;
  match (drops.accept(7, in files, position)) { some(_) => return 22; none => {} }
  if (granted(in authority, "/selected/first.txt") || observed.accepted != 1) return 23;
  if (observed.entered != observed.ended) return 34;
  return 0;
}
function main(): i32 on thread.main { return match (attempt check()) { success(value) => value; failure(_) => 90; }; }
