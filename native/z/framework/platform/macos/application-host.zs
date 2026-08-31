import AppKit from "AppKit/AppKit.h";
import native from "zapp_desktop.h";
import { Mutex, Once, OnceLifetime } from "std/sync";
import { thread } from "std/thread";

internal struct MacOSApplicationHostState {
  result: i32;
}

internal class MacOSApplicationHost {
  readonly smokeMode: boolean;
  readonly state: Mutex<MacOSApplicationHostState>;
  readonly application: AppKit.NSApplication on thread.main;

  function result(): i32 {
    return this.state.withLock((in state): i32 => state.result);
  }

  function setResult(result: i32): void {
    this.state.withLock((inout state): void => {
      state.result = result;
    });
  }
}

const applicationHost = Once<MacOSApplicationHost>();

internal function initializeMacOSApplicationHost():
  OnceLifetime<MacOSApplicationHost> on thread.main {
  const smokeMode = native.zapp_desktop_requested_smoke_mode();
  const application: AppKit.NSApplication =
    AppKit.NSApplication.sharedApplication;
  return applicationHost.initialize(new MacOSApplicationHost({
    smokeMode,
    state: Mutex(MacOSApplicationHostState({
      result: smokeMode ? 41 : 0,
    })),
    application,
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
  native.ZAppDesktopBridge.stopRunLoop();
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
