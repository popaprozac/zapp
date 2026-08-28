import { ServiceLifecycleError } from "../api/zapp/service.zs";

export struct WindowError {
  id: String;
  message: String;
}

export struct PlatformError {
  code: i32;
  message: String;
}

export enum ApplicationError {
  lifecycle ServiceLifecycleError,
  window WindowError,
  platform PlatformError,
}
