import { ServiceLifecycleError } from "../api/zapp/service.zs";
import { MenuError } from "./menu.zs";

export struct WindowError {
  id: String;
  message: String;
}

export struct PlatformError {
  code: i32;
  message: String;
}

export enum ApplicationState {
  configuring,
  running,
  stopped,
}

export readonly struct ApplicationStateError {
  state: ApplicationState;
  message: String;
}

export enum ApplicationError {
  state ApplicationStateError,
  lifecycle ServiceLifecycleError,
  menu MenuError,
  window WindowError,
  platform PlatformError,
}
