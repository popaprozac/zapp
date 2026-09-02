// Deliberately fails during every engine incarnation. The restart smoke uses
// this build-only module to prove that the configured retry cap is enforced
// without weakening an application's ordinary worker API.
throw new Error("intentional application-worker restart smoke failure");

export function onMessage(channel: string, payload: string): void {}
