import { thread } from "std/thread";

export enum NotificationPermission {
  notDetermined,
  denied,
  granted,
  provisional,
}

export readonly struct NotificationOptions {
  id: Option<String> = Option<String>.none;
  title: String;
  subtitle: Option<String> = Option<String>.none;
  body: Option<String> = Option<String>.none;
}

export enum NotificationOperation {
  permissionStatus,
  requestPermission,
  show,
}

export struct NotificationError {
  operation: NotificationOperation;
  message: String;
}

internal type NotificationPermissionOutcome = Result<
  NotificationPermission,
  NotificationError
>;

internal type NotificationShowOutcome = Result<String, NotificationError>;

internal type NotificationPermissionOperation = async () =>
  NotificationPermissionOutcome on thread.main;

internal type NotificationShowOperation = async (
  options: NotificationOptions
) => NotificationShowOutcome on thread.main;

internal struct NotificationBackend {
  permissionStatus: NotificationPermissionOperation;
  requestPermission: NotificationPermissionOperation;
  show: NotificationShowOperation;
}

function notificationUnavailable(
  operation: NotificationOperation,
  message: String
): NotificationError {
  return NotificationError({ operation, message: move message });
}

async function inactivePermissionStatus(
): NotificationPermission throws NotificationError on thread.main {
  throw notificationUnavailable(
    NotificationOperation.permissionStatus,
    "notification access is unavailable before Application.run()"
  );
}

async function inactiveRequestPermission(
): NotificationPermission throws NotificationError on thread.main {
  throw notificationUnavailable(
    NotificationOperation.requestPermission,
    "notification access is unavailable before Application.run()"
  );
}

async function inactiveShowNotification(
  options: NotificationOptions
): String throws NotificationError on thread.main {
  throw notificationUnavailable(
    NotificationOperation.show,
    "notification access is unavailable before Application.run()"
  );
}

function inactiveNotificationBackend(): NotificationBackend on thread.main {
  const permissionStatus: NotificationPermissionOperation = async () =>
    attempt await inactivePermissionStatus();
  const requestPermission: NotificationPermissionOperation = async () =>
    attempt await inactiveRequestPermission();
  const show: NotificationShowOperation = async (options) =>
    attempt await inactiveShowNotification(move options);
  return NotificationBackend({ permissionStatus, requestPermission, show });
}

async function unsupportedPermissionStatus(
): NotificationPermission throws NotificationError on thread.main {
  throw notificationUnavailable(
    NotificationOperation.permissionStatus,
    "notifications are unsupported by the active application platform"
  );
}

async function unsupportedRequestPermission(
): NotificationPermission throws NotificationError on thread.main {
  throw notificationUnavailable(
    NotificationOperation.requestPermission,
    "notifications are unsupported by the active application platform"
  );
}

async function unsupportedShowNotification(
  options: NotificationOptions
): String throws NotificationError on thread.main {
  throw notificationUnavailable(
    NotificationOperation.show,
    "notifications are unsupported by the active application platform"
  );
}

internal function unsupportedNotificationBackend(
): NotificationBackend on thread.main {
  const permissionStatus: NotificationPermissionOperation = async () =>
    attempt await unsupportedPermissionStatus();
  const requestPermission: NotificationPermissionOperation = async () =>
    attempt await unsupportedRequestPermission();
  const show: NotificationShowOperation = async (options) =>
    attempt await unsupportedShowNotification(move options);
  return NotificationBackend({ permissionStatus, requestPermission, show });
}

class NotificationManagerState on thread.main {
  backend: NotificationBackend;

  async function permissionStatus(
  ): NotificationPermission throws NotificationError {
    const outcome = await this.backend.permissionStatus();
    return match (outcome) {
      success(permission) => permission;
      failure(error) => throw error;
    };
  }

  async function requestPermission(
  ): NotificationPermission throws NotificationError {
    const outcome = await this.backend.requestPermission();
    return match (outcome) {
      success(permission) => permission;
      failure(error) => throw error;
    };
  }

  async function show(
    options: NotificationOptions
  ): String throws NotificationError {
    const outcome = await this.backend.show(move options);
    return match (outcome) {
      success(identifier) => move identifier;
      failure(error) => throw error;
    };
  }

  function start(inout this, backend: NotificationBackend): void {
    this.backend = backend;
  }

  function stop(inout this): void {
    this.backend = inactiveNotificationBackend();
  }
}

export readonly class NotificationManager on thread.main {
  internal readonly state: NotificationManagerState;

  internal constructor() {
    this.state = new NotificationManagerState({
      backend: inactiveNotificationBackend(),
    });
  }

  async function permissionStatus(
  ): NotificationPermission throws NotificationError on thread.main {
    return try await this.state.permissionStatus();
  }

  async function requestPermission(
  ): NotificationPermission throws NotificationError on thread.main {
    return try await this.state.requestPermission();
  }

  async function show(
    options: NotificationOptions
  ): String throws NotificationError on thread.main {
    return try await this.state.show(move options);
  }

  internal function start(
    inout this,
    backend: NotificationBackend
  ): void on thread.main {
    this.state.start(backend);
  }

  internal function stop(inout this): void on thread.main {
    this.state.stop();
  }
}

internal function createNotificationManager(
): NotificationManager on thread.main {
  return new NotificationManager();
}
