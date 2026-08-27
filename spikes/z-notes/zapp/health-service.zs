export struct HealthService {
  function status(): String {
    return "ready";
  }
}

export function createHealthService(): HealthService {
  return HealthService();
}
