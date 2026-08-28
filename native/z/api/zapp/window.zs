import {
  Window as FrameworkWindow,
  WindowManager as FrameworkWindowManager,
  WindowOptions as FrameworkWindowOptions,
} from "../../framework/window.zs";
import {
  WindowError as FrameworkWindowError,
} from "../../framework/application-error.zs";

export type Window = FrameworkWindow;
export type WindowManager = FrameworkWindowManager;
export type WindowOptions = FrameworkWindowOptions;
export type WindowError = FrameworkWindowError;
