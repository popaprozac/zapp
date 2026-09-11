# Context menus

Approved public direction: present the existing `Menu` / `Command` model through
`window.showContextMenu(...)`. A context menu is another presentation, not a
second command system.

## Public contract (implementation in progress)

```zs
try await window.showContextMenu(
  in menu,
  ContextMenuOptions({ x: 120, y: 80 }),
);
```

```ts
await currentWindow().showContextMenu([
  { command: renameNote },
  { type: "separator" },
  { label: "Delete", action: () => deleteNote(note.id) },
], { x: event.clientX, y: event.clientY });
```

- Completion means the popup closed. Dismissal is successful and invokes no
  command. Selection invokes one command. A TypeScript action may return a
  promise; that work is not part of popup completion.
- The native Z method is async and main-executor-bound. This does not imply that
  AppKit's native tracking loop is a nonblocking Z scheduler primitive.
- Coordinates are explicit: viewport CSS coordinates in TypeScript; top-left
  content-area logical coordinates in Z. Platform code performs conversion.
  Cursor fallbacks and element anchors are not part of the first tier.
- Existing `menu` permission and selected capabilities apply. Frontend requests
  may only target their originating window; a caller-supplied window ID does not
  confer authority. Native Z can explicitly select an owned window.
- Errors use `MenuError`: invalid definition or coordinates, unavailable window,
  conflicting presentation, and platform failure. Permission failures retain
  their shared permission-error type.
- Commands, submenus, and separators are the initial content. Application-menu
  role groups must not be installed accidentally by a context-menu renderer.
  Context-appropriate roles require explicit validation before support.

## Lifetime and implementation checkpoints

1. Generalize frontend menu ownership into independent presentation records.
   The same `Command` can be in the application menu and a popup. Closing or
   replacing one presentation must not detach the other.
2. Give each popup a native presentation session with deterministic retirement.
   Navigation, owner-window closure, and shutdown invalidate the session before
   native callbacks can run again. Conflicting native popups fail explicitly.
3. Deliver the selected command ID in the popup response, not a separate
   fire-and-forget event. TypeScript can retire the presentation and invoke the
   selected callback without racing an out-of-band click against cleanup.
4. Wire the public Z and TS methods, bridge authorization, and macOS rendering.
   Verify reentrancy and dismissal through the real AppKit tracking loop.
5. Add Z Notes UI, native/unit/lifetime tests, developer docs, and a bounded
   visual smoke. Do not claim the public feature is available before this path
   is connected and checked.

No global last-pointer tracking, arbitrary callback expiry timer, or parallel
legacy menu implementation is introduced.

## Foundation verification

```sh
bun test runtime/menu-presentations.test.ts runtime/menu-api.test.ts
bun native/z/testing/context-menu.ts
```

The second command checks the platform-independent lifecycle with Stage 0 and
the source-current native emitter, strict Clang at `-O0` / `-O2`, and UBSan.
Compiler and executable processes have hard deadlines and process-tree cleanup.
It opens no windows and is not evidence for AppKit tracking-loop behavior.

This checkpoint does not expose `showContextMenu` yet. Native presentation,
bridge routing, lifecycle hooks, public exports, and the Z Notes UI follow.
