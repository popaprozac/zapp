# macOS platform implementation

This directory is Zapp's internal macOS backend. It is not part of the public
`zapp` package surface.

- `application-host.zs` owns the `NSApplication` identity, synchronized host
  result, smoke-mode state, native run loop, run-loop wake event, and
  deterministic host lifetime.
- `application.zs` owns application startup, lifecycle ordering, and
  deterministic shutdown around that host lifetime.
- `runtime.zs` is the small composition facade that initializes and shuts down
  the split application, message-routing, and native-window runtime modules.
- `application-runtime.zs` owns shared application state, response delivery,
  and the authoritative open and retired native-window registries.
- `message-handler.zs` owns the retained `WKScriptMessageHandler` adapter and
  transfers each native WebKit callback into checked Z routing.
- `message-routing.zs` owns request decoding, cancellation, capability checks,
  built-in operations, generated service dispatch, and structured completion.
- `window-backend.zs` adapts the cross-platform `WindowBackend` contract to
  macOS operations.
- `window-delegate.zs` owns the retained `NSWindowDelegate` adapter, window
  lifecycle/focus/resize policy, and the Z-owned registry close callback.
- `window-runtime.zs` defines the retained AppKit/WebKit object graph for one
  window; `application-runtime.zs` owns the authoritative open and retired
  registries.
- `window-construction.zs` builds that native graph, installs protocol and
  delegate adapters, configures navigation/injection, and starts the request.
- `window-geometry.zs` converts Z window dimensions to and from the native
  `CGRect` representation with explicit, checked numeric construction.
- `scheme-handler.zs` owns the retained WebKit protocol adapter, packaged-origin
  and path policy, asset routing, MIME/encoding selection, response delivery,
  and the private typed `raw objc` boundary that transfers Brotli output
  directly into `NSData` ownership.
- `configured-assets.zs` is the editor-safe empty asset catalog. Packaged builds
  replace it with a generated Z module whose `embed.StaticBytes` values point
  directly at compiler-emitted process-lifetime storage.
- `configured-webview.zs` is the editor-safe empty WebView configuration.
  Builds replace it with generated typed Z values for the frontend origin,
  bundled bootstrap, development mode, and trusted injection catalog.
- `configured-smoke.zs` is the editor-safe disabled smoke configuration. Test
  builds replace it with a generated enabled value alongside the conditionally
  linked native smoke object; ordinary production builds contain neither.
- `webview-injections.zs` owns bootstrap/window identity scripts, configured
  injection-profile validation and ordering, JSON-safe CSS wrapping, phase
  mapping, and `WKUserScript` registration.
- `navigation.zs` owns logical URL resolution, frontend-origin comparison, the
  retained `WKNavigationDelegate` adapter, completion-block decisions, and
  navigation-failure policy.
- `response-delivery.zs` owns JavaScript-safe response envelopes and delivery
  policy. Smoke builds route completion observations through the generated
  `configured-smoke.zs` module into the test-only native harness.
- `desktop-smoke.m` is isolated native test support for DOM verification and
  bounded smoke shutdown. It is compiled only for smoke/sanitizer builds and
  is not application policy or part of production binaries.
- `desktop-smoke.h` and `desktop-smoke.h.zd` describe only that test harness.
  Ordinary production builds do not compile or link the smoke source.

The production macOS backend contains no tracked handwritten Objective-C
implementation or umbrella header. Objective-C emitted into build caches is Z
compiler output, and the remaining checked SDK imports come directly from
Foundation, AppKit, WebKit, and libcompression.

The migration rule is that policy moves toward these Z modules while
Objective-C shrinks toward generated adapters or small ABI glue. New public
framework behavior belongs in the cross-platform framework layer, not in this
directory.
