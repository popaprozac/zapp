export struct WorkerAddition {
  left: i32;
  right: i32;
}

export struct WorkerProbeService {
  function add(input: WorkerAddition): i32 {
    return input.left + input.right;
  }
}

export function createWorkerProbeService(): WorkerProbeService {
  return WorkerProbeService();
}
