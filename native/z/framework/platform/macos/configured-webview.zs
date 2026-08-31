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
