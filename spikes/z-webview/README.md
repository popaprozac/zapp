# Z WebView round trip

This deterministic macOS smoke builds Zapp's framework-owned Z core through the
ordinary `ZAPP_NATIVE_LANG=z` path, links its transitional Objective-C
AppKit/WebKit host, and opens one visible window. The page clicks its own button,
posts a JSON envelope through `WKScriptMessageHandler`, routes it through Z's
typed `BridgeMessage` and process-wide `Application`, receives a typed response,
updates the DOM, and closes shortly afterward.

Run it from the repository root:

```sh
bun run spike:z-webview
```

Expected terminal evidence:

```text
visible WebView round trip window=1 request=42 ok=true payload={"message":"héllo from WebKit"}
```

The Objective-C host is migration scaffolding, not the intended application
architecture. The fixed-point native Z compiler does not yet ingest
Objective-C/WebKit metadata; Stage 0 already does, as proven by Z's AppKit
applications. Once that metadata crosses the fixed-point boundary, window,
WebView, protocol-adapter, and run-loop ownership move into the Z `Application`
without changing the typed router or public embedding ABI.
