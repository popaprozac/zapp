// Source-tree fallback. The Zapp CLI replaces this module in an isolated
// application build with the roots declared by security.filesystem.allow.
internal function configuredFilesystemAllowAtIndex(
  index: usize
): Option<String> {
  return Option.none;
}
