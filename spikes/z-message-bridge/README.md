# Z message-bridge pressure test

This opt-in smoke test exercises the framework-owned `native/z/` core through
the same builder used by `ZAPP_NATIVE_LANG=z`. It began as an isolated
Nim-to-Z probe; Phase 0 promoted its evidence into the ordinary Zapp build.

The current production ABI is:

```c
void zapp_handle_message_from_window(
  void *app,
  char *message,
  int32_t window_id
);
```

The framework-owned core exports the useful message boundary directly:

```z
export c function zapp_route_message_owned(
  message: String,
  windowId: i32
): void {
  zapp_route_message_from_z(message, windowId);
}
```

The generated Z wrapper rejects null or invalid UTF-8, makes one owned copy,
and destroys it after the Z function returns. Its adjacent `.zd` contract
selects the exact host callback; Clang supplies the fixed parameter's
`const char *` identity, which Z exposes as a non-owning `cstring` call
boundary. The Phase 0 C host is intentionally tiny: it proves archive linkage,
runtime initialization, UTF-8 routing, and deterministic shutdown without
retaining a Nim compatibility layer.

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
at `../z-lang/.z-cache/bootstrap/z`, then finally `z` from `PATH`. It validates
the compiler contract pinned in `native/z/compiler-contract.json`, stages and
builds the same Z static library as the CLI, links the strict-C Phase 0 host,
sends a UTF-8 JSON envelope through C → Z → C, and shuts the runtime down.

This deliberately does not add a raw pointer type to Z. If Z eventually needs
to inspect a host context rather than use its own application root, that should
be a nominal, borrowed opaque-handle design reviewed independently.
