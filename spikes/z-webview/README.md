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

The fixed-point native Z compiler imports AppKit/WebKit metadata and the
main-executor Z `DesktopApplication` now creates and strongly owns the window,
WebView, configuration, content controller, registration owner, protocol
adapter, and deterministic registration guard. The Objective-C host owns the
process/run-loop bridge and smoke-test callbacks but keeps only weak access to
the Z-owned UI identities. Z narrows the dynamic message body with
`instanceof`, copies `NSString` into owned Z storage, and routes it without
changing the public embedding ABI.

This migration also serves as compiler pressure evidence. Importing the wider
AppKit/WebKit graph originally exposed a native stored-view traversal that
reached 55.1 GiB before being stopped; Objective-C references now terminate at
their native identity and the same build completes in seconds. Z still spells
separate `NSRect` and `CGRect` construction because their cross-framework
canonical typedef identity is a known compiler follow-up.
