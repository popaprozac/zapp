// Windows power state + events. Mirrors darwin/platform.m's IOKit path.
//
// getPowerState (runtime App.getPowerState, seeded into the bootstrap
// config) comes from GetSystemPowerStatus. Change events arrive via
// WM_POWERBROADCAST on a hidden top-level window (message-only windows
// do NOT receive broadcast power messages):
//   PBT_APMSUSPEND          → app:will-sleep (109)
//   PBT_APMRESUMEAUTOMATIC  → app:did-wake (110)
//   PBT_APMPOWERSTATUSCHANGE→ app:power-state-changed (114)
//   PBT_POWERSETTINGCHANGE  → battery % (115) / power-saving (114)

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "power.h"

extern HINSTANCE zapp_get_hinstance(void);
extern int zapp_app_dispatch(int event_id, const char* data);

#define ZAPP_EVENT_APP_WILL_SLEEP           109
#define ZAPP_EVENT_APP_DID_WAKE             110
#define ZAPP_EVENT_APP_POWER_STATE_CHANGED  114
#define ZAPP_EVENT_APP_BATTERY_LEVEL_CHANGED 115

// SYSTEM_POWER_STATUS.SystemStatusFlag bit 0 = "battery saver on"
// (Win10+); older SDKs may not define the field name, so mask manually.
#ifndef SYSTEM_STATUS_FLAG_POWER_SAVING_ON
#define SYSTEM_STATUS_FLAG_POWER_SAVING_ON 0x01
#endif

// These power-setting GUIDs aren't reliably exported by MinGW's import
// libs (GUID_POWER_SAVING_STATUS is Win10+); define locally from winnt.h.
static const GUID ZAPP_GUID_BATTERY_PCT =
    {0xa7ad8041,0xb45a,0x4cae,{0x87,0xa3,0xee,0xcb,0xb4,0x68,0xa9,0xe1}};
static const GUID ZAPP_GUID_POWER_SAVING =
    {0xe00958c0,0xc213,0x4ace,{0xac,0x77,0xfe,0xcc,0xed,0x2e,0xee,0xa5}};

static HWND zapp_power_hwnd = NULL;
static HPOWERNOTIFY zapp_power_pct_notify = NULL;
static HPOWERNOTIFY zapp_power_saver_notify = NULL;

// Build the {source, lowPowerMode, percent, charging} JSON the runtime
// PowerState contract expects. Static buffer (called on the UI thread).
const char* windows_get_power_state(void) {
    static char buf[160];
    SYSTEM_POWER_STATUS s;
    if (!GetSystemPowerStatus(&s)) {
        snprintf(buf, sizeof(buf),
            "{\"source\":\"ac\",\"lowPowerMode\":false,\"percent\":null,\"charging\":false}");
        return buf;
    }
    // ACLineStatus: 0 = offline (battery), 1 = online (AC), 255 = unknown.
    const char* source = (s.ACLineStatus == 0) ? "battery" : "ac";
    // BatteryFlag bit 3 (8) = charging; 128 = no system battery.
    int charging = (s.BatteryFlag != 255) && (s.BatteryFlag & 8);
    int low = (s.SystemStatusFlag & SYSTEM_STATUS_FLAG_POWER_SAVING_ON) ? 1 : 0;

    char percent_field[24];
    if (s.BatteryLifePercent <= 100) {
        snprintf(percent_field, sizeof(percent_field), "%d", (int)s.BatteryLifePercent);
    } else {
        // 255 = unknown, or no battery → null (matches darwin's -1→null).
        snprintf(percent_field, sizeof(percent_field), "null");
    }

    snprintf(buf, sizeof(buf),
        "{\"source\":\"%s\",\"lowPowerMode\":%s,\"percent\":%s,\"charging\":%s}",
        source, low ? "true" : "false", percent_field, charging ? "true" : "false");
    return buf;
}

static LRESULT CALLBACK power_wndproc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_POWERBROADCAST) {
        switch (wParam) {
            case PBT_APMSUSPEND:
                zapp_app_dispatch(ZAPP_EVENT_APP_WILL_SLEEP, "{}");
                return TRUE;
            case PBT_APMRESUMEAUTOMATIC:
                zapp_app_dispatch(ZAPP_EVENT_APP_DID_WAKE, "{}");
                return TRUE;
            case PBT_APMPOWERSTATUSCHANGE:
                // AC↔battery or charging change → full power-state event.
                zapp_app_dispatch(ZAPP_EVENT_APP_POWER_STATE_CHANGED,
                                  windows_get_power_state());
                return TRUE;
            case PBT_POWERSETTINGCHANGE: {
                POWERBROADCAST_SETTING* p = (POWERBROADCAST_SETTING*)lParam;
                if (!p) break;
                if (IsEqualGUID(&p->PowerSetting, &ZAPP_GUID_BATTERY_PCT)) {
                    zapp_app_dispatch(ZAPP_EVENT_APP_BATTERY_LEVEL_CHANGED,
                                      windows_get_power_state());
                } else if (IsEqualGUID(&p->PowerSetting, &ZAPP_GUID_POWER_SAVING)) {
                    zapp_app_dispatch(ZAPP_EVENT_APP_POWER_STATE_CHANGED,
                                      windows_get_power_state());
                }
                return TRUE;
            }
            default: break;
        }
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

void windows_power_init(void) {
    if (zapp_power_hwnd) return;
    static const wchar_t* cls = L"ZappPowerNotify";
    WNDCLASSEXW wc = {0};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = power_wndproc;
    wc.hInstance = zapp_get_hinstance();
    wc.lpszClassName = cls;
    RegisterClassExW(&wc);
    // A hidden top-level window (NOT message-only): suspend/resume and
    // status-change broadcasts only reach windows with a desktop parent.
    zapp_power_hwnd = CreateWindowExW(0, cls, L"", WS_OVERLAPPED, 0, 0, 0, 0,
                                      NULL, NULL, zapp_get_hinstance(), NULL);
    if (!zapp_power_hwnd) return;

    // PBT_APMPOWERSTATUSCHANGE (AC/battery/charge) is delivered without
    // registration; battery % and power-saving toggle need explicit
    // PowerSetting notifications.
    zapp_power_pct_notify = RegisterPowerSettingNotification(
        zapp_power_hwnd, &ZAPP_GUID_BATTERY_PCT, DEVICE_NOTIFY_WINDOW_HANDLE);
    zapp_power_saver_notify = RegisterPowerSettingNotification(
        zapp_power_hwnd, &ZAPP_GUID_POWER_SAVING, DEVICE_NOTIFY_WINDOW_HANDLE);
}

void windows_power_shutdown(void) {
    if (zapp_power_pct_notify) { UnregisterPowerSettingNotification(zapp_power_pct_notify); zapp_power_pct_notify = NULL; }
    if (zapp_power_saver_notify) { UnregisterPowerSettingNotification(zapp_power_saver_notify); zapp_power_saver_notify = NULL; }
    if (zapp_power_hwnd) { DestroyWindow(zapp_power_hwnd); zapp_power_hwnd = NULL; }
}
