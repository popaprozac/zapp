import { Tray as FrameworkTray, TrayManager as FrameworkTrayManager,
  TrayOptions as FrameworkTrayOptions, TrayError as FrameworkTrayError } from "../../framework/tray.zs";
import { thread } from "std/thread";

export type Tray = FrameworkTray;
export type TrayManager = FrameworkTrayManager;
export type TrayOptions = FrameworkTrayOptions;
export type TrayError = FrameworkTrayError;
