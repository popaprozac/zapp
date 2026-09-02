export struct WorkerMessage {
  channel: String;
  payload: String;
}

export enum WorkerCommand {
  message WorkerMessage,
}

export struct WorkerResponse {
  channel: String;
  payload: String;
}
