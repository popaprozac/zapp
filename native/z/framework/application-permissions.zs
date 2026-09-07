// Immutable native policy compiled from zapp.config.ts. This is deliberately
// separate from descriptive ApplicationMetadata and is never supplied by
// WebView content.
export readonly struct ApplicationPermissions {
  applicationQuit: boolean = false;
  windowCreate: boolean = true;
  menu: boolean = true;
  fsRead: boolean = false;
  fsWrite: boolean = false;
  clipboardRead: boolean = false;
  clipboardWrite: boolean = false;
  notifications: boolean = false;
  shellOpen: boolean = false;
  shellReveal: boolean = false;
  shellTrash: boolean = false;
}
