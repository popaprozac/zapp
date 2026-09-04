// Immutable native policy compiled from zapp.config.ts. This is deliberately
// separate from descriptive ApplicationMetadata and is never supplied by
// WebView content.
export readonly struct ApplicationPermissions {
  windowCreate: boolean = true;
  menu: boolean = true;
}
