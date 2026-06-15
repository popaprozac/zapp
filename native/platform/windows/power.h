// Windows power state + change events. Mirrors the darwin power API.

#ifndef ZAPP_WINDOWS_POWER_H
#define ZAPP_WINDOWS_POWER_H

#ifdef _WIN32

// {source, lowPowerMode, percent, charging} JSON (caller must not free).
const char* windows_get_power_state(void);

// Create the hidden notification window + register power-setting
// notifications. Call from windows_platform_init (main thread).
void windows_power_init(void);
void windows_power_shutdown(void);

#endif // _WIN32
#endif
