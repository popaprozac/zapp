import { thread } from "std/thread";
import { BridgeDocument } from "./bridge-document.zs";
import { RelatedDocumentIdentity } from "./related-documents.zs";
import { FilesystemAuthority } from "./filesystem-authority.zs";
import { WindowEvents } from "./window-events.zs";
import { WindowDropPosition, WindowFilesDroppedEvent, WindowFileDragEnteredEvent,
  WindowFileDragMovedEvent, WindowFileDragEndedEvent } from "./events.zs";

// The native backend supplies validated existing regular files, never renderer
// arguments. A gesture belongs to one acknowledged document and one OS sequence.
internal class WindowFileDrops on thread.main {
  readonly id: String;
  readonly enabled: boolean;
  readonly document: BridgeDocument;
  readonly authority: FilesystemAuthority;
  readonly events: WindowEvents;
  private identity: Option<RelatedDocumentIdentity>;
  private sequence: isize;
  private pendingPosition: Option<WindowDropPosition>;
  private lastPosition: WindowDropPosition;

  constructor(id: String, enabled: boolean, document: BridgeDocument,
    authority: FilesystemAuthority, events: WindowEvents) {
    this.id = move id;
    this.enabled = enabled;
    this.document = document;
    this.authority = authority;
    this.events = events;
    this.identity = Option.none;
    this.sequence = -1;
    this.pendingPosition = Option.none;
    this.lastPosition = WindowDropPosition({ x: 0, y: 0 });
  }

  function begin(inout this, sequence: isize, position: WindowDropPosition): boolean {
    this.clear();
    if (!this.enabled) return false;
    this.identity = this.document.readyIdentity();
    this.sequence = sequence;
    if (!this.current(sequence)) { this.clear(); return false; }
    this.lastPosition = position;
    const event = WindowFileDragEnteredEvent({ windowId: copy this.id, position });
    this.events.publishFileDragEntered(in event);
    if (!this.current(sequence)) { this.clear(); return false; }
    return true;
  }

  function current(sequence: isize): boolean {
    if (!this.enabled || this.sequence != sequence) return false;
    return match (in this.identity) {
      some(identity) => this.document.isCurrent(in identity);
      none => false;
    };
  }

  function update(inout this, sequence: isize, position: WindowDropPosition): boolean {
    if (!this.current(sequence)) { this.clear(); return false; }
    if (position.x != this.lastPosition.x || position.y != this.lastPosition.y) {
      this.lastPosition = position;
      this.pendingPosition = Option.some(position);
    }
    return true;
  }

  function takeMovement(inout this): Option<WindowFileDragMovedEvent> {
    if (!this.current(this.sequence)) { this.clear(); return Option.none; }
    const position = match (this.pendingPosition) { some(value) => value; none => return Option.none; };
    this.pendingPosition = Option.none;
    const event = WindowFileDragMovedEvent({ windowId: copy this.id, position });
    this.events.publishFileDragMoved(in event);
    return Option.some(move event);
  }

  function hasMovement(): boolean {
    return match (in this.pendingPosition) { some(_) => true; none => false; };
  }

  function clear(inout this): void {
    const active = match (in this.identity) { some(_) => true; none => false; };
    this.identity = Option.none;
    this.sequence = -1;
    this.pendingPosition = Option.none;
    if (active) {
      const event = WindowFileDragEndedEvent({ windowId: copy this.id });
      this.events.publishFileDragEnded(in event);
    }
  }

  function accept(inout this, sequence: isize, in paths: Array<String>, position: WindowDropPosition
  ): Option<WindowFilesDroppedEvent> {
    if (paths.length == 0 || !this.current(sequence)) { this.clear(); return Option.none; }
    const grants = match (attempt this.authority.prepareFileGrants(in paths)) {
      success(value) => value;
      failure(_) => { this.clear(); return Option.none; }
    };
    let canonical = Array<String>();
    for (const grant of grants) { canonical.push(copy grant.root); }
    const allowed = this.events.publishFileDropRequested(in this.id, in canonical, position);
    // A callback may close or replace the document. No grant exists yet.
    if (!allowed || !this.current(sequence)) { this.clear(); return Option.none; }
    this.authority.commitFileGrants(in grants);
    this.clear();
    const event = WindowFilesDroppedEvent({ windowId: copy this.id, paths: move canonical, position });
    this.events.publishFilesDropped(in event);
    return Option.some(move event);
  }
}
