// Desired requests and native observations are deliberately separate.
// No platform handles, timers, or synthetic completion events live here.
internal struct WindowPresentationState {
  maximized: boolean = false;
  fullscreen: boolean = false;
  fullscreenTransition: boolean = false;
  pendingMaximized: Option<boolean> = Option<boolean>.none;
  pendingFullscreen: Option<boolean> = Option<boolean>.none;

  function requestMaximized(inout this, value: boolean): void {
    this.pendingMaximized = Option.some(value);
  }

  function requestFullscreen(inout this, value: boolean): void {
    this.pendingFullscreen = Option.some(value);
  }

  function takeMaximizedRequest(inout this): Option<boolean> {
    if (this.fullscreen || this.fullscreenTransition) return Option.none;
    const pending = this.pendingMaximized;
    this.pendingMaximized = Option.none;
    return pending;
  }

  function takeFullscreenRequest(inout this): Option<boolean> {
    if (this.fullscreenTransition) return Option.none;
    const pending = this.pendingFullscreen;
    this.pendingFullscreen = Option.none;
    return match (pending) {
      some(value) => {
        if (value == this.fullscreen) return Option<boolean>.none;
        this.fullscreenTransition = true;
        select Option.some(value);
      }
      none => Option.none;
    };
  }

  function beginFullscreen(inout this): void {
    this.fullscreenTransition = true;
  }

  function completeFullscreen(inout this, value: boolean): boolean {
    const changed = this.fullscreen != value;
    this.fullscreen = value;
    this.fullscreenTransition = false;
    return changed;
  }

  function observeMaximized(inout this, value: boolean): boolean {
    // Fullscreen changes geometry, but is not a maximize/unmaximize operation.
    if (this.fullscreen || this.fullscreenTransition) return false;
    const changed = this.maximized != value;
    this.maximized = value;
    return changed;
  }
}
