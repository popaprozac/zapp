# Z message-bridge pressure test

This opt-in smoke test exercises the framework-owned `native/z/` core through
the same builder used by `ZAPP_NATIVE_LANG=z`. It began as an isolated
Nim-to-Z probe; Phase 0 promoted its evidence into the ordinary Zapp build.

The framework-owned core exports the useful ingress boundary directly:

```z
export c function zapp_route_message_owned(
  message: String,
  windowId: i32
): void {
  const response = routeMessage(in message);
  zapp_deliver_response_from_z(
    response.payload,
    response.id,
    response.ok,
    windowId
  );
}
```

`routeMessage` parses the `{t,id,m,a}` WebView envelope once, produces a typed
`BridgeMessage`, dispatches `__zapp:ping`, and returns `BridgeResponse`. The
first internal model deliberately stores `a` as its exact serialized JSON
boundary text; arbitrary JSON values therefore do not spread through the
application core. The response crosses back to the host as typed fields rather
than being wrapped in a second loosely typed envelope:

```c
void zapp_deliver_response_from_z(
  const char *payload,
  uint64_t request_id,
  bool ok,
  int32_t window_id
);
```

The generated Z wrapper rejects null or invalid UTF-8, makes one owned copy,
and destroys it after the Z function returns. Its adjacent `.zd` contract
selects the exact host callback; Clang supplies the fixed parameter's
`const char *` identity, which Z exposes as a non-owning `cstring` call
boundary. The C host is intentionally tiny: it proves archive linkage, runtime
initialization, exact `u64` request identity, UTF-8 JSON routing, typed response
delivery, and deterministic shutdown without retaining a Nim compatibility
layer.

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
builds the same Z static library as the CLI, links the strict-C host,
sends a UTF-8 JSON envelope through C → Z → C, and shuts the runtime down.
It selects the internal `bridge` host explicitly; ordinary
`ZAPP_NATIVE_LANG=z` builds now link the visible desktop host.

The Z router itself also has native fixed-point tests:

```sh
../z-lang/.z-cache/bootstrap/z test native/z/bridge.test.zs
```

They cover the exact `u64.max` request ID, non-ASCII payloads, malformed JSON,
and unknown methods.

This deliberately does not add a raw pointer type to Z. If Z eventually needs
to inspect a host context rather than use its own application root, that should
be a nominal, borrowed opaque-handle design reviewed independently.
