# build/

Place platform-specific build inputs here. The CLI picks them up
automatically at `bun run package` time.

## macOS

Drop any of these into `build/macos/`:

- `icon.icon` — Icon Composer bundle (best for macOS 26+ liquid glass)
- `icon.icns` — traditional icon
- `icon.iconset` — source set (CLI converts via `iconutil`)
- `icon.png` — single 1024×1024 (CLI compiles via `actool`)
- `Info.plist.extra` — partial plist; keys here merge into the
  generated `Info.plist` at package time.
- `app.entitlements` — code-signing entitlements. Passed to
  `codesign --entitlements` during both `zapp dev` and
  `zapp package`. Map entries in `zapp.config.ts →
  macos.entitlements` override matching keys from this file.

### Icon priority

1. `macos.icon` path set in `zapp.config.ts` (explicit override)
2. `build/macos/icon.{icon,icns,iconset,png}` (this directory)
3. Framework default (Zapp logo)

### Info.plist.extra example

```xml
<key>LSUIElement</key>
<true/>
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

Keep only the keys you want to add or override. Don't wrap in
`<plist>` or `<dict>` — just the key/value pairs.

### Entitlements example

`build/macos/app.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
```

Privileged entitlements (`com.apple.developer.*`,
`com.apple.security.app-sandbox`) require a real
`macos.signingIdentity`. Ad-hoc signing silently ignores them.

## Windows

Placeholder for future Windows build inputs (`icon.ico`, app
manifest, resource file). Windows packaging is in progress.
