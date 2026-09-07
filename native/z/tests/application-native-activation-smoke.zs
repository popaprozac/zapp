import AppKit from "AppKit/AppKit.h";
import Foundation from "Foundation/Foundation.h";
import console from "std/console";
import { thread } from "std/thread";
import {
  ApplicationOpenURLRequestedEvent,
  ApplicationReopenRequestedEvent,
} from "../framework/application-activation.zs";
import {
  ApplicationEventSubscriptionError,
  createApplicationEvents,
} from "../framework/application-events.zs";
import {
  initializeMacOSApplicationHost,
  runMacOSApplicationLoop,
} from "../framework/platform/macos/application-host.zs";

// Drive the actual NSApplicationDelegate selectors without registering the
// test executable as the machine's handler for an application URL scheme.
function sendURLs(in application: AppKit.NSApplication, in urls: Foundation.NSArray): void = raw objc {
  [application.delegate application:application openURLs:urls];
}

function sendReopen(in application: AppKit.NSApplication): boolean = raw objc {
  return [application.delegate applicationShouldHandleReopen:application hasVisibleWindows:NO];
}

class Observation on thread.main {
  urls: i32;
  reopens: i32;
  lastURL: String;
}

function run(): i32 throws ApplicationEventSubscriptionError on thread.main {
  const events = createApplicationEvents();
  events.configureActivation(Array<String>("znotes"));
  const lifetime = initializeMacOSApplicationHost(events);
  const observation = new Observation({ urls: 0, reopens: 0, lastURL: "" });
  const urls = try events.openURLRequested.subscribe(
    move (in event: ApplicationOpenURLRequestedEvent): void => {
      observation.urls = observation.urls + 1;
      observation.lastURL = copy event.url;
    }
  );
  const reopen = try events.reopenRequested.subscribe(
    move (in event: ApplicationReopenRequestedEvent): void => {
      observation.reopens = observation.reopens + 1;
    }
  );
  const app = AppKit.NSApplication.sharedApplication;
  const good = Foundation.NSURL.URLWithString("znotes://notes/42");
  const denied = Foundation.NSURL.URLWithString("https://outside.invalid/private");
  if (good == null || denied == null) return 1;
  sendURLs(in app, Foundation.NSArray.arrayWithObject(good));
  if (sendReopen(in app)) return 2;
  sendURLs(in app, Foundation.NSArray.arrayWithObject(denied));
  if (observation.urls != 0 || observation.reopens != 0) return 3;
  events.startActivation();
  if (observation.urls != 1 || observation.reopens != 1) return 4;
  if (observation.lastURL != "znotes://notes/42") return 5;
  sendURLs(in app, Foundation.NSArray.arrayWithObject(good));
  if (observation.urls != 2) return 6;
  // An accepted request during startup must not enter a fresh blocking loop.
  events.start(move (): void => {});
  events.requestQuit();
  if (runMacOSApplicationLoop() != 0) return 8;
  sendURLs(in app, Foundation.NSArray.arrayWithObject(good));
  if (observation.urls != 2) return 7;
  events.finish();
  console.log("AppKit activation selectors preserved startup, live delivery, scheme filtering, and shutdown");
  return 0;
}

function main(): i32 on thread.main {
  return match (attempt run()) {
    success(status) => status;
    failure(_) => 99;
  };
}
