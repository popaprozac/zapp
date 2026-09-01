export struct WorkerMessage {
  left: i32;
  right: i32;
}

export enum WorkerCommand {
  message WorkerMessage,
}
