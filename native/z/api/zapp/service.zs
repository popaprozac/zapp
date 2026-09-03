import { ApplicationMetadata } from "../../framework/application-metadata.zs";
import { thread } from "std/thread";

export readonly struct ApplicationPaths {
  executable: String;
  resources: String;
  data: String;
  config: String;
  cache: String;
}

export readonly struct ApplicationContext {
  metadata: ApplicationMetadata;
  arguments: readonly Array<String>;
  paths: ApplicationPaths;
}

export enum ServiceLifecyclePhase {
  start,
  stop,
}

export struct ServiceLifecycleError {
  service: String;
  phase: ServiceLifecyclePhase;
  message: String;
}

export trait ServiceLifecycle {
  function start(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main;

  function stop(
    in context: ApplicationContext
  ): void throws ServiceLifecycleError on thread.main;
}

export function serviceLifecycleError(
  service: String,
  phase: ServiceLifecyclePhase,
  message: String
): ServiceLifecycleError {
  return ServiceLifecycleError({
    service: move service,
    phase,
    message: move message,
  });
}
