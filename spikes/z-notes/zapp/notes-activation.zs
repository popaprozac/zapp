import {
  Application,
  ApplicationEventSubscription,
  ApplicationEventSubscriptionError,
  ApplicationOpenURLRequestedEvent,
  ApplicationReopenRequestedEvent,
} from "zapp";
import { Window, WindowOptions } from "zapp/window";
import { NotesService } from "./notes-service.zs";
import { noteIdFromURL } from "./notes-route.zs";
import console from "std/console";
import { thread } from "std/thread";

function openRequestedNote(
  app: Application,
  in notes: NotesService,
  in url: String
): void on thread.main {
  const id = match (noteIdFromURL(in url)) {
    some(value) => value;
    none => {
      console.log("Z Notes ignored an unsupported deep-link route");
      return;
    }
  };
  const all = notes.list();
  for (const note of all) {
    if (note.id != id) continue;
    const opened = attempt app.windows.create(WindowOptions({
      title: `Z Notes — ${note.title}`,
      url: `/notes?note=${id}`,
      inject: Array<String>("base"),
      width: 720,
      height: 460,
    }));
    match (opened) {
      success(window) => console.log(`deep link opened note ${id} in ${window.id}`);
      failure(error) => console.error(`could not open requested note: ${error.message}`);
    }
    return;
  }
  console.log(`deep link requested unknown note ${id}`);
}

export struct NoteActivationSubscriptions {
  reopen: ApplicationEventSubscription;
  links: ApplicationEventSubscription;
}

export function observeNoteActivation(
  app: Application,
  notes: NotesService,
  window: Window
): NoteActivationSubscriptions throws ApplicationEventSubscriptionError on thread.main {
  const linkHandler: (in event: ApplicationOpenURLRequestedEvent) => void on thread.main =
    move (in event: ApplicationOpenURLRequestedEvent): void => {
      openRequestedNote(app, in notes, in event.url);
    };
  const reopenHandler: (in event: ApplicationReopenRequestedEvent) => void on thread.main =
    move (in event: ApplicationReopenRequestedEvent): void => {
      window.show();
      console.log("Z Notes handled an application reopen request");
    };
  const links = try app.events.openURLRequested.subscribe(linkHandler);
  const reopen = try app.events.reopenRequested.subscribe(reopenHandler);
  return NoteActivationSubscriptions({ reopen, links });
}
