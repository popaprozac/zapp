// macOS tray / status item — NSStatusItem wrapper.
//
// Every tray is keyed by a JS-supplied numeric id. The runtime picks
// ids monotonically; native uses them as dispatch keys so subsequent
// setIcon / setMenu / destroy calls land on the right item.

#ifndef ZAPP_DARWIN_TRAY_H
#define ZAPP_DARWIN_TRAY_H

#include <stdint.h>
#include <stdbool.h>

// Create a status item. `payload_json` is the full bridge envelope
// {t, m, a:{id, icon, title?, tooltip?, template, menu?}}; tray.m
// extracts the "a" dict and builds the NSStatusItem.
void darwin_tray_create_from_payload(const char* payload_json);

// Update an existing status item. Same payload shape — only the keys
// present are applied.
void darwin_tray_set_icon_from_payload(const char* payload_json);
void darwin_tray_set_title_from_payload(const char* payload_json);
void darwin_tray_set_tooltip_from_payload(const char* payload_json);
void darwin_tray_set_menu_from_payload(const char* payload_json);
void darwin_tray_destroy_from_payload(const char* payload_json);

// Attach a window to a tray slot — left-click toggles visibility, the
// window auto-positions relative to the icon and (by default) hides on
// blur. Coexists with a previously-set menu: when both are configured,
// left-click drives the window and right-click opens the menu.
//
// Payload: { a: { id, windowId, position, dismissOnBlur, toggleOnClick,
//                 offset: { x, y } } }
//   - id          — tray id
//   - windowId    — numeric WindowHandle.id from runtime
//   - position    — "centerBelow" | "centerAbove" | "rightCenter"
//   - dismissOnBlur, toggleOnClick — booleans
//   - offset      — pixel adjustment from the computed anchor point
void darwin_tray_attach_window_from_payload(const char* payload_json);

// Detach the window. If the slot still has a menu configured, restores
// `item.menu = menu` so the system handles clicks again. Otherwise
// reverts to plain click-event mode.
void darwin_tray_detach_window_from_payload(const char* payload_json);

#endif
