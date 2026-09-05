import {
  Window as FrameworkWindow,
  WindowManager as FrameworkWindowManager,
  WindowOptions as FrameworkWindowOptions,
} from "../../framework/window.zs";
import {
  WindowError as FrameworkWindowError,
} from "../../framework/application-error.zs";
import {
  WindowEvents as FrameworkWindowEvents,
  WindowEventSubscription as FrameworkWindowEventSubscription,
  WindowEventSubscriptionError as FrameworkWindowEventSubscriptionError,
} from "../../framework/window-events.zs";
import {
  WindowBlurredEvent as FrameworkWindowBlurredEvent,
  WindowCloseRequestedEvent as FrameworkWindowCloseRequestedEvent,
  WindowClosedEvent as FrameworkWindowClosedEvent,
  WindowEvent as FrameworkWindowEvent,
  WindowFocusedEvent as FrameworkWindowFocusedEvent,
  WindowNavigationRequestedEvent as FrameworkWindowNavigationRequestedEvent,
  WindowResizedEvent as FrameworkWindowResizedEvent,
  WindowSize as FrameworkWindowSize,
} from "../../framework/events.zs";

export type Window = FrameworkWindow;
export type WindowManager = FrameworkWindowManager;
export type WindowOptions = FrameworkWindowOptions;
export type WindowError = FrameworkWindowError;
export type WindowEvents = FrameworkWindowEvents;
export type WindowEvent = FrameworkWindowEvent;
export type WindowEventSubscription = FrameworkWindowEventSubscription;
export type WindowEventSubscriptionError = FrameworkWindowEventSubscriptionError;
export type WindowFocusedEvent = FrameworkWindowFocusedEvent;
export type WindowBlurredEvent = FrameworkWindowBlurredEvent;
export type WindowResizedEvent = FrameworkWindowResizedEvent;
export type WindowSize = FrameworkWindowSize;
export type WindowCloseRequestedEvent = FrameworkWindowCloseRequestedEvent;
export type WindowClosedEvent = FrameworkWindowClosedEvent;
export type WindowNavigationRequestedEvent = FrameworkWindowNavigationRequestedEvent;
