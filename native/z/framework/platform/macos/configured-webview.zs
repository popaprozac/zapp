internal struct ConfiguredWebViewInjection {
  profile: String;
  source: String;
  phase: i32;
}

internal function configuredFrontendOrigin(): String {
  return "zapp://app/";
}

internal function configuredFrontendIsDevelopment(): boolean {
  return false;
}

internal function configuredWebViewBootstrap(): String {
  return "";
}

internal function configuredWebViewInjectionCount(): usize {
  return 0;
}

internal function configuredWebViewInjectionAtIndex(
  index: usize
): Option<ConfiguredWebViewInjection> {
  return Option.none;
}

internal function configuredNavigationProfileExists(
  in profile: String
): boolean {
  return profile == "default";
}

internal function configuredNavigationAllowsSelf(
  in profile: String
): boolean {
  return profile == "default";
}

internal function configuredNavigationOriginAtIndex(
  in profile: String,
  index: usize
): Option<String> {
  return Option.none;
}

// Reserved now so the compiled security catalog has one stable shape when the
// explicit app.shell.openExternal(...) manager lands. Navigation never opens
// an external URL as an implicit side effect.
internal function configuredNavigationExternalSchemeAtIndex(
  in profile: String,
  index: usize
): Option<String> {
  return Option.none;
}
