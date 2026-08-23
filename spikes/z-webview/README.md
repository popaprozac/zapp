# Z WebView round trip

This deterministic macOS smoke builds Zapp's framework-owned Z core through the
ordinary `ZAPP_NATIVE_LANG=z` path, links its transitional Objective-C
AppKit/WebKit host, and opens one visible window. The page clicks its own button,
uses the production document-start bootstrap's canonical `bridge.invoke()` API,
posts through `WKScriptMessageHandler`, routes through Z's typed `BridgeMessage`
and process-wide `Application`, resolves through `_onInvokeResult()`, verifies
the updated DOM, and closes shortly afterward.

Run it from the repository root:

```sh
bun run spike:z-webview
```

The bounded sanitizer driver rebuilds the generated Z core with UBSan, enables
Objective-C zombies for the complete registration/message/teardown lifecycle,
and runs ASan only when an empty startup probe proves the installed Apple
runtime works:

```sh
bun run spike:z-webview:sanitize
```

Every launched binary has a hard timeout and is killed if it does not exit, so
a broken host sanitizer runtime cannot leave a CPU-intensive fixture behind.

Expected terminal evidence:

```text
visible WebView round trip window=1 request=1 ok=true payload={"message":"héllo from WebKit"}
```

The Objective-C process/run-loop and window construction host is migration
scaffolding, not the intended application architecture. The fixed-point native
Z compiler already imports WebKit metadata, emits the Z-owned protocol adapter,
retains its registration guard in the process-wide `Application`, narrows the
dynamic message body with `instanceof`, and copies `NSString` into owned Z
storage. Window/WebView ownership is the next boundary to move without changing
the typed router or public embedding ABI.
