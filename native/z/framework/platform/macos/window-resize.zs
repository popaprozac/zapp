import QuartzCore from "QuartzCore/CADisplayLink.h";
import clock from "QuartzCore/CABase.h";
import WebKit from "WebKit/WebKit.h";
import objc from "std/objc";
import { thread } from "std/thread";

function interpolateFrame(start: WebKit.CGRect, target: WebKit.CGRect, progress: f64): WebKit.CGRect {
  if (progress <= 0) return start;
  if (progress >= 1) return target;
  const remaining = 1 - progress;
  const eased = progress < 0.5 ? 4 * progress * progress * progress : 1 - 4 * remaining * remaining * remaining;
  return WebKit.NSMakeRect(
    start.origin.x + (target.origin.x - start.origin.x) * eased,
    start.origin.y + (target.origin.y - start.origin.y) * eased,
    start.size.width + (target.size.width - start.size.width) * eased,
    start.size.height + (target.size.height - start.size.height) * eased
  );
}

function invalidateDisplay(in link: QuartzCore.CADisplayLink | null): void on thread.main {
  if (link != null) link.invalidate();
}

function equalFrames(left: WebKit.CGRect, right: WebKit.CGRect): boolean {
  return left.origin.x == right.origin.x && left.origin.y == right.origin.y
    && left.size.width == right.size.width && left.size.height == right.size.height;
}

function equalSizes(left: WebKit.CGRect, right: WebKit.CGRect): boolean {
  return left.size.width == right.size.width && left.size.height == right.size.height;
}

function createDisplay(in window: MacOSWindow): QuartzCore.CADisplayLink on thread.main {
  const link = window.displayLinkWithTarget(window, selector: objc.selector(MacOSWindow.onDisplay));
  const screen = window.screen;
  if (screen != null) {
    const maximum = f32(screen.maximumFramesPerSecond);
    if (maximum > 0) {
      link.preferredFrameRateRange = QuartzCore.CAFrameRateRangeMake(maximum < 60 ? maximum : f32(60), maximum, maximum);
    }
  }
  link.addToRunLoop(WebKit.NSRunLoop.mainRunLoop, forMode: WebKit.NSRunLoopCommonModes);
  return link;
}

// Internal AppKit geometry controller. Public Window APIs remain platform-neutral.
internal class MacOSWindow extends WebKit.NSWindow on thread.main {
  private displayLink: QuartzCore.CADisplayLink | null;
  private startFrame: WebKit.CGRect;
  private targetFrame: WebKit.CGRect;
  private restoreFrame: WebKit.CGRect;
  private hasRestoreFrame: boolean;
  private preparingZoom: boolean;
  private applyingFrame: boolean;
  private zoomTransition: boolean;
  private targetIsZoomed: boolean;
  private updateRestoreOnCompletion: boolean;
  private startedAt: f64;
  private duration: f64;
  private animating: boolean;
  private shuttingDown: boolean;
  private systemResize: boolean;
  private needsDisplay: boolean;

  constructor(frame: WebKit.CGRect, style: WebKit.NSWindowStyleMask) {
    super.initWithContentRect(frame,
      styleMask: style,
      backing: WebKit.NSBackingStoreBuffered, defer: false);
    this.displayLink = null;
    this.startFrame = frame;
    this.targetFrame = frame;
    this.restoreFrame = frame;
    this.hasRestoreFrame = false;
    this.preparingZoom = false;
    this.applyingFrame = false;
    this.zoomTransition = false;
    this.targetIsZoomed = false;
    this.updateRestoreOnCompletion = false;
    this.startedAt = 0;
    this.duration = 0;
    this.animating = false;
    this.shuttingDown = false;
    this.systemResize = false;
    this.needsDisplay = true;
    this.releasedWhenClosed = false;
  }

  override function isZoomed(): boolean as "isZoomed" {
    if (this.animating && this.zoomTransition) return this.targetIsZoomed;
    return super.isZoomed();
  }

  override function animationResizeTime(frame: WebKit.CGRect): f64 as "animationResizeTime:" {
    if (this.preparingZoom) return 0;
    return super.animationResizeTime(frame);
  }

  override function resize(inout this, frame: WebKit.CGRect, display: boolean, animate: boolean): void as "setFrame:display:animate:" {
    if (this.systemResize) {
      super.setFrame(frame, display: display, animate: animate);
      return;
    }
    if (this.preparingZoom || this.applyingFrame) {
      super.setFrame(frame, display: display, animate: false);
      return;
    }
    // Replacing a transition always disconnects its old tick source first.
    invalidateDisplay(this.displayLink);
    this.displayLink = null;
    this.animating = false;
    this.zoomTransition = false;
    const start = this.frame;
    const wasZoomed = super.isZoomed();
    const updateRestore = this.hasRestoreFrame && !wasZoomed && !equalSizes(start, frame);
    const duration = super.animationResizeTime(frame);
    const screen = this.screen;
    if (!animate || this.shuttingDown || WebKit.NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion || duration <= 0 || screen == null || equalFrames(start, frame)) {
      this.applyingFrame = true;
      super.setFrame(frame, display: display);
      this.applyingFrame = false;
      if (updateRestore) this.restoreFrame = this.frame;
      return;
    }
    this.startFrame = start;
    this.targetFrame = frame;
    this.duration = duration;
    this.startedAt = clock.CACurrentMediaTime();
    this.needsDisplay = display;
    this.updateRestoreOnCompletion = updateRestore;
    this.animating = true;
    this.displayLink = createDisplay(this);
  }

  override function setFrame(inout this, frame: WebKit.CGRect, display: boolean): void as "setFrame:display:" {
    if (this.systemResize || this.preparingZoom || this.applyingFrame) {
      super.setFrame(frame, display: display);
      return;
    }
    this.animating = false;
    invalidateDisplay(this.displayLink);
    this.displayLink = null;
    const start = this.frame;
    const wasZoomed = super.isZoomed();
    const updateRestore = this.hasRestoreFrame && !wasZoomed && !equalSizes(start, frame);
    super.setFrame(frame, display: display);
    if (updateRestore) this.restoreFrame = this.frame;
  }

  override function zoom(inout this, in sender: objc.Object | null): void as "zoom:" {
    if (this.systemResize) {
      super.zoom(sender);
      return;
    }
    const start = this.frame;
    const interrupted = this.animating;
    const previousTarget = this.targetFrame;
    this.animating = false;
    invalidateDisplay(this.displayLink);
    this.displayLink = null;
    if (interrupted) {
      this.applyingFrame = true;
      super.setFrame(previousTarget, display: false);
      this.applyingFrame = false;
    }
    // Let AppKit commit its standard/user-frame state before reading the
    // intended target. Our nested overrides suppress only that preparation's
    // animation; normal delegates and native constraints still run.
    this.preparingZoom = true;
    super.zoom(sender);
    this.preparingZoom = false;
    let target = this.frame;
    let targetZoomed = super.isZoomed();
    // An unchanged target includes a delegate veto. Never manufacture a
    // restore transition after AppKit declined the operation.
    if (equalFrames(start, target)) return;
    if (targetZoomed) {
      if (!this.hasRestoreFrame) {
        this.restoreFrame = start;
        this.hasRestoreFrame = true;
      }
    } else if (this.hasRestoreFrame) target = this.restoreFrame;

    const screen = this.screen;
    if (this.shuttingDown || WebKit.NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion || screen == null) {
      this.applyingFrame = true;
      super.setFrame(target, display: true);
      this.applyingFrame = false;
      if (!targetZoomed) this.hasRestoreFrame = false;
      return;
    }
    this.applyingFrame = true;
    super.setFrame(start, display: true);
    this.applyingFrame = false;
    // AppKit computes duration from the current frame to the requested frame.
    // Asking while still at the prepared target can yield a zero duration.
    const duration = super.animationResizeTime(target);
    if (duration <= 0) {
      this.applyingFrame = true;
      super.setFrame(target, display: true);
      this.applyingFrame = false;
      if (!targetZoomed) this.hasRestoreFrame = false;
      return;
    }
    this.startFrame = start;
    this.targetFrame = target;
    this.duration = duration;
    this.startedAt = clock.CACurrentMediaTime();
    this.needsDisplay = true;
    this.zoomTransition = true;
    this.targetIsZoomed = targetZoomed;
    this.updateRestoreOnCompletion = false;
    this.animating = true;
    this.displayLink = createDisplay(this);
  }

  function onDisplay(inout this, in link: QuartzCore.CADisplayLink): void as "display:" {
    const active = this.displayLink;
    // A queued callback from an invalidated source must not advance a newer
    // animation. This compares object identity, without invoking isEqual:.
    if (active == null || link != active) {
      link.invalidate();
      return;
    }
    if (!this.animating || this.shuttingDown) return;
    const reducedMotion = WebKit.NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    const progress = reducedMotion ? 1.0 : (link.targetTimestamp - this.startedAt) / this.duration;
    const frame = interpolateFrame(this.startFrame, this.targetFrame, progress);
    if (progress >= 1) {
      this.animating = false;
      invalidateDisplay(this.displayLink);
      this.displayLink = null;
      if (this.zoomTransition && !this.targetIsZoomed) this.hasRestoreFrame = false;
    }
    const display = this.needsDisplay;
    this.applyingFrame = true;
    super.setFrame(frame, display: display);
    this.applyingFrame = false;
    if (progress >= 1 && this.updateRestoreOnCompletion) this.restoreFrame = this.frame;
  }

  override function close(inout this): void as "close" {
    this.shuttingDown = true;
    this.animating = false;
    invalidateDisplay(this.displayLink);
    this.displayLink = null;
    // performClose: has already consulted the cancellable delegate request.
    // Hide the accepted window before AppKit delivers windowWillClose: and
    // before any application close observer can perform slower cleanup.
    super.orderOut(null);
    super.close();
  }

  function cancelResize(inout this): void as "zappCancelResize" {
    // AppKit can notify its delegate synchronously during our own frame apply.
    if (this.applyingFrame || this.preparingZoom) return;
    this.animating = false;
    this.zoomTransition = false;
    invalidateDisplay(this.displayLink);
    this.displayLink = null;
  }

  function setSystemResize(inout this, active: boolean): void as "zappSetSystemResize:" {
    this.systemResize = active;
    this.animating = false;
    this.zoomTransition = false;
    invalidateDisplay(this.displayLink);
    this.displayLink = null;
  }

}
