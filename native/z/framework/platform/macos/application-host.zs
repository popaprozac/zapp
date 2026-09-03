import AppKit from "AppKit/AppKit.h";
import objc from "std/objc";
import { Mutex, Once, OnceLifetime } from "std/sync";
import { thread } from "std/thread";
import { ApplicationEvents } from "../../application-events.zs";
import {
  configuredMacOSApplicationSmokeMode,
} from "./configured-smoke.zs";

internal struct MacOSApplicationHostState {
  result: i32;
}

internal class MacOSApplicationHost {
  readonly smokeMode: boolean;
  readonly state: Mutex<MacOSApplicationHostState>;
  readonly application: AppKit.NSApplication on thread.main;
  readonly delegate: objc.Adapter<AppKit.NSApplicationDelegate> on thread.main;

  function result(): i32 {
    return this.state.withLock((in state): i32 => state.result);
  }

  function setResult(result: i32): void {
    this.state.withLock((inout state): void => {
      state.result = result;
    });
  }
}

class MacOSApplicationDelegate on thread.main
  implements AppKit.NSApplicationDelegate {
  readonly events: ApplicationEvents;

  function shouldTerminate(
    in application: AppKit.NSApplication
  ): AppKit.NSApplicationTerminateReply as "applicationShouldTerminate:" {
    let events = this.events;
    return events.approveQuit()
      ? AppKit.NSTerminateNow
      : AppKit.NSTerminateCancel;
  }
}

const applicationHost = Once<MacOSApplicationHost>();

internal function initializeMacOSApplicationHost(
  events: ApplicationEvents
):
  OnceLifetime<MacOSApplicationHost> on thread.main {
  const smokeMode = configuredMacOSApplicationSmokeMode();
  const application: AppKit.NSApplication =
    AppKit.NSApplication.sharedApplication;
  const nativeDelegate = new MacOSApplicationDelegate({ events });
  const delegate = objc.adapt<AppKit.NSApplicationDelegate>(nativeDelegate);
  application.delegate = delegate;
  return applicationHost.initialize(new MacOSApplicationHost({
    smokeMode,
    state: Mutex(MacOSApplicationHostState({
      result: smokeMode ? 41 : 0,
    })),
    application,
    delegate,
  }));
}

internal function macOSApplicationSmokeMode(): boolean {
  const host = applicationHost.get();
  return host.smokeMode;
}

internal function setMacOSApplicationResult(
  result: i32
): void {
  const host = applicationHost.get();
  host.setResult(result);
}

internal function stopMacOSRunLoop(): void on thread.main {
  const host = applicationHost.get();
  const application = host.application;
  application.stop(null);
  const wake = AppKit.NSEvent.otherEventWithType(
    AppKit.NSEventTypeApplicationDefined,
    location: AppKit.NSMakePoint(0.0, 0.0),
    modifierFlags: 0,
    timestamp: 0.0,
    windowNumber: 0,
    context: null,
    subtype: 0,
    data1: 0,
    data2: 0
  );
  if (wake != null) application.postEvent(wake, atStart: true);
}

internal function runMacOSApplicationLoop(): i32 on thread.main {
  const host = applicationHost.get();
  const application = host.application;
  application.setActivationPolicy(
    AppKit.NSApplicationActivationPolicyRegular
  );
  application.activate();
  application.run();
  return host.result();
}

export c function zapp_macos_application_smoke_mode(): i32 {
  return macOSApplicationSmokeMode() ? 1 : 0;
}

export c function zapp_macos_application_set_result(
  result: i32
): void {
  setMacOSApplicationResult(result);
}
