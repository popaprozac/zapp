import embed from "std/embed";

export struct WorkerModule {
  source: embed.StaticBytes;
  name: String;
}

export enum WorkerLifecycle {
  stopped i32,
  cancelled i32,
  failed i32,
}
