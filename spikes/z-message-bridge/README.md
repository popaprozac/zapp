# Z message-bridge pressure test

This opt-in spike exercises Z inside Zapp's real webview-to-router boundary
without making the pre-alpha Z compiler a mandatory Zapp build dependency.

The current production ABI is:

```c
void zapp_handle_message_from_window(
  void *app,
  char *message,
  int32_t window_id
);
```

The Nim runtime does not inspect `app`, but the legacy Zen-C runtime still does.
`host.nim` therefore preserves that ABI as a compatibility adapter and forwards
the useful arguments to Z:

```z
export c function zapp_route_message_owned(
  message: String,
  windowId: i32
): void {
  zapp_route_message_from_z(message, windowId);
}
```

The generated Z wrapper rejects null or invalid UTF-8, makes one owned copy,
and destroys it after the Z function returns. The final call models the current
Nim router entry point. Its adjacent `.zd` contract selects the exact function;
Clang supplies the fixed parameter's `const char *` identity, which Z exposes as
a non-owning `cstring` call boundary. While routing remains in Nim, Nim makes its
existing second owned copy. Moving envelope parsing and dispatch into Z will
remove that temporary extra copy.

The destination is not a permanent Nim/Z split. Zapp is an early experiment
that can be rewritten incrementally until its application model, routing, and
platform services are Z. Z's Objective-C/C/C++ imports let each existing native
seam remain callable while Z implementations replace the Nim and handwritten
Objective-C code behind it.

Run from the repository root:

```sh
bun run spike:z-bridge
```

The runner uses `ZAPP_Z_COMPILER` when set, otherwise the fixed-point compiler
at `../z-lang/.z-cache/bootstrap/z`, then finally `z` from `PATH`. It builds the
Z static library, links it into a Nim executable, initializes the generated Z
embedding runtime, sends a UTF-8 JSON envelope through Nim → Z → Nim, and shuts
the runtime down cleanly.

The Nim compiler is selected from `ZAPP_NIM`, then `~/.nimble/bin/nim`, and
finally `nim` from `PATH`.

This deliberately does not add a raw pointer type to Z. If Z eventually needs
to inspect a host context rather than use its own application root, that should
be a nominal, borrowed opaque-handle design reviewed independently.
