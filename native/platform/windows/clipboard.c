// Windows clipboard — Win32 clipboard + WIC PNG codec.
// See clipboard.h for the cross-platform contract (mirrors darwin).

#define WIN32_LEAN_AND_MEAN
#ifndef COBJMACROS
#define COBJMACROS
#endif
#include <windows.h>
#include <shellapi.h>   // DragQueryFileW (CF_HDROP)
#include <wincodec.h>   // WIC — PNG encode/decode
#include <wincrypt.h>   // CryptBinaryToStringA / CryptStringToBinaryA
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "clipboard.h"

// --- UTF helpers (malloc'd returns) ---

static char* cb_utf16_to_utf8(const wchar_t* w) {
    if (!w) return NULL;
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    if (n <= 0) return NULL;
    char* s = (char*)malloc((size_t)n);
    if (!s) return NULL;
    WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL);
    return s;
}

static wchar_t* cb_utf8_to_utf16(const char* s) {
    if (!s) return NULL;
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t* w = (wchar_t*)malloc((size_t)n * sizeof(wchar_t));
    if (!w) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    return w;
}

// Clipboard sessions are short critical sections: open, copy in/out,
// close. NULL owner window is fine for a get/set roundtrip.
static bool cb_open(void) {
    // The clipboard is a contended global — another process can hold it
    // for a moment. A few quick retries beat failing the API call.
    for (int i = 0; i < 5; i++) {
        if (OpenClipboard(NULL)) return true;
        Sleep(10);
    }
    return false;
}

// --- Text ---

char* windows_clipboard_read_text(void) {
    if (!cb_open()) return NULL;
    char* result = NULL;
    HANDLE h = GetClipboardData(CF_UNICODETEXT);
    if (h) {
        const wchar_t* w = (const wchar_t*)GlobalLock(h);
        if (w) {
            result = cb_utf16_to_utf8(w);
            GlobalUnlock(h);
        }
    }
    CloseClipboard();
    return result;
}

bool windows_clipboard_write_text(const char* text) {
    if (!text) return false;
    wchar_t* w = cb_utf8_to_utf16(text);
    if (!w) return false;
    size_t bytes = (wcslen(w) + 1) * sizeof(wchar_t);
    HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!h) { free(w); return false; }
    void* mem = GlobalLock(h);
    memcpy(mem, w, bytes);
    GlobalUnlock(h);
    free(w);

    if (!cb_open()) { GlobalFree(h); return false; }
    EmptyClipboard();
    bool ok = SetClipboardData(CF_UNICODETEXT, h) != NULL;
    if (!ok) GlobalFree(h); // ownership only transfers on success
    CloseClipboard();
    return ok;
}

// --- HTML ("HTML Format") ---
//
// CF_HTML is UTF-8 text with a mandatory ASCII header carrying byte
// offsets:
//   Version:0.9
//   StartHTML:NNNNNNNNNN
//   EndHTML:NNNNNNNNNN
//   StartFragment:NNNNNNNNNN
//   EndFragment:NNNNNNNNNN
// Read returns the fragment slice; write wraps the fragment in the
// minimal valid document.

static UINT cb_html_format(void) {
    static UINT fmt = 0;
    if (!fmt) fmt = RegisterClipboardFormatA("HTML Format");
    return fmt;
}

static int cb_header_offset(const char* data, const char* key) {
    const char* p = strstr(data, key);
    if (!p) return -1;
    return atoi(p + strlen(key));
}

char* windows_clipboard_read_html(void) {
    if (!cb_open()) return NULL;
    char* result = NULL;
    HANDLE h = GetClipboardData(cb_html_format());
    if (h) {
        const char* data = (const char*)GlobalLock(h);
        if (data) {
            SIZE_T total = GlobalSize(h);
            int start = cb_header_offset(data, "StartFragment:");
            int end = cb_header_offset(data, "EndFragment:");
            // Fall back to the full HTML block when fragment offsets are
            // missing or mangled (some producers only fill Start/EndHTML).
            if (start < 0 || end < 0 || end <= start || (SIZE_T)end > total) {
                start = cb_header_offset(data, "StartHTML:");
                end = cb_header_offset(data, "EndHTML:");
            }
            if (start >= 0 && end > start && (SIZE_T)end <= total) {
                int len = end - start;
                result = (char*)malloc((size_t)len + 1);
                if (result) {
                    memcpy(result, data + start, (size_t)len);
                    result[len] = '\0';
                }
            }
            GlobalUnlock(h);
        }
    }
    CloseClipboard();
    return result;
}

bool windows_clipboard_write_html(const char* html) {
    if (!html) return false;
    const char* prefix =
        "<html><body><!--StartFragment-->";
    const char* suffix =
        "<!--EndFragment--></body></html>";
    // Header uses fixed-width 10-digit offsets so lengths are stable.
    const char* header_fmt =
        "Version:0.9\r\n"
        "StartHTML:%010d\r\n"
        "EndHTML:%010d\r\n"
        "StartFragment:%010d\r\n"
        "EndFragment:%010d\r\n";
    int header_len = snprintf(NULL, 0, header_fmt, 0, 0, 0, 0);
    int frag_len = (int)strlen(html);
    int start_html = header_len;
    int start_frag = header_len + (int)strlen(prefix);
    int end_frag = start_frag + frag_len;
    int end_html = end_frag + (int)strlen(suffix);

    int total = end_html;
    char* buf = (char*)malloc((size_t)total + 1);
    if (!buf) return false;
    snprintf(buf, (size_t)header_len + 1, header_fmt,
             start_html, end_html, start_frag, end_frag);
    memcpy(buf + header_len, prefix, strlen(prefix));
    memcpy(buf + start_frag, html, (size_t)frag_len);
    memcpy(buf + end_frag, suffix, strlen(suffix));
    buf[total] = '\0';

    HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, (SIZE_T)total + 1);
    if (!h) { free(buf); return false; }
    void* mem = GlobalLock(h);
    memcpy(mem, buf, (size_t)total + 1);
    GlobalUnlock(h);
    free(buf);

    if (!cb_open()) { GlobalFree(h); return false; }
    EmptyClipboard();
    bool ok = SetClipboardData(cb_html_format(), h) != NULL;
    if (ok) {
        // Match darwin: HTML writes also deposit a plain-text rendering?
        // No — darwin writes html only; keep semantics identical.
    } else {
        GlobalFree(h);
    }
    CloseClipboard();
    return ok;
}

// --- Files (CF_HDROP) ---

char* windows_clipboard_read_files(void) {
    if (!cb_open()) return strdup("[]");
    HANDLE h = GetClipboardData(CF_HDROP);
    if (!h) { CloseClipboard(); return strdup("[]"); }
    HDROP drop = (HDROP)h;
    UINT count = DragQueryFileW(drop, 0xFFFFFFFF, NULL, 0);

    // Build the JSON array on the heap, growing as needed.
    size_t cap = 256;
    size_t len = 0;
    char* out = (char*)malloc(cap);
    if (!out) { CloseClipboard(); return strdup("[]"); }
    out[len++] = '[';
    for (UINT i = 0; i < count; i++) {
        UINT wlen = DragQueryFileW(drop, i, NULL, 0);
        wchar_t* wpath = (wchar_t*)malloc(((size_t)wlen + 1) * sizeof(wchar_t));
        if (!wpath) continue;
        DragQueryFileW(drop, i, wpath, wlen + 1);
        char* path = cb_utf16_to_utf8(wpath);
        free(wpath);
        if (!path) continue;
        // JSON-escape (backslashes + quotes dominate Windows paths).
        size_t need = strlen(path) * 2 + 4;
        if (len + need >= cap) {
            while (len + need >= cap) cap *= 2;
            char* grown = (char*)realloc(out, cap);
            if (!grown) { free(path); break; }
            out = grown;
        }
        if (i > 0) out[len++] = ',';
        out[len++] = '"';
        for (const char* p = path; *p; p++) {
            if (*p == '\\' || *p == '"') out[len++] = '\\';
            out[len++] = *p;
        }
        out[len++] = '"';
        free(path);
    }
    out[len++] = ']';
    out[len] = '\0';
    CloseClipboard();
    return out;
}

// --- Image (CF_DIB ↔ PNG via WIC) ---

static IWICImagingFactory* cb_wic(void) {
    static IWICImagingFactory* factory = NULL;
    if (!factory) {
        // CoInitializeEx already ran in windows_platform_init; calling
        // again from a worker thread is handled by the S_FALSE path.
        CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
        CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER,
                         &IID_IWICImagingFactory, (void**)&factory);
    }
    return factory;
}

// Read CF_BITMAP as an HBITMAP, PNG-encode via WIC into a heap buffer.
static bool cb_read_image_png(uint8_t** out_data, int32_t* out_len) {
    *out_data = NULL;
    *out_len = 0;
    IWICImagingFactory* wic = cb_wic();
    if (!wic) return false;
    if (!cb_open()) return false;
    HBITMAP hbmp = (HBITMAP)GetClipboardData(CF_BITMAP);
    bool ok = false;
    IWICBitmap* bitmap = NULL;
    IStream* stream = NULL;
    IWICBitmapEncoder* encoder = NULL;
    IWICBitmapFrameEncode* frame = NULL;

    if (hbmp &&
        SUCCEEDED(IWICImagingFactory_CreateBitmapFromHBITMAP(
            wic, hbmp, NULL, WICBitmapUseAlpha, &bitmap)) &&
        SUCCEEDED(CreateStreamOnHGlobal(NULL, TRUE, &stream)) &&
        SUCCEEDED(IWICImagingFactory_CreateEncoder(
            wic, &GUID_ContainerFormatPng, NULL, &encoder)) &&
        SUCCEEDED(IWICBitmapEncoder_Initialize(
            encoder, stream, WICBitmapEncoderNoCache)) &&
        SUCCEEDED(IWICBitmapEncoder_CreateNewFrame(encoder, &frame, NULL)) &&
        SUCCEEDED(IWICBitmapFrameEncode_Initialize(frame, NULL)) &&
        SUCCEEDED(IWICBitmapFrameEncode_WriteSource(
            frame, (IWICBitmapSource*)bitmap, NULL)) &&
        SUCCEEDED(IWICBitmapFrameEncode_Commit(frame)) &&
        SUCCEEDED(IWICBitmapEncoder_Commit(encoder))) {
        HGLOBAL hg = NULL;
        if (SUCCEEDED(GetHGlobalFromStream(stream, &hg))) {
            SIZE_T size = GlobalSize(hg);
            void* bytes = GlobalLock(hg);
            if (bytes && size > 0) {
                *out_data = (uint8_t*)malloc(size);
                if (*out_data) {
                    memcpy(*out_data, bytes, size);
                    *out_len = (int32_t)size;
                    ok = true;
                }
                GlobalUnlock(hg);
            }
        }
    }
    if (frame) IWICBitmapFrameEncode_Release(frame);
    if (encoder) IWICBitmapEncoder_Release(encoder);
    if (stream) IStream_Release(stream);
    if (bitmap) IWICBitmap_Release(bitmap);
    CloseClipboard();
    return ok;
}

// Decode PNG bytes via WIC into a top-down 32bpp BGRA DIB and put it on
// the clipboard as CF_DIB (the most interoperable bitmap form).
static bool cb_write_image_png(const uint8_t* data, int32_t len) {
    IWICImagingFactory* wic = cb_wic();
    if (!wic || !data || len <= 0) return false;

    bool ok = false;
    IWICStream* stream = NULL;
    IWICBitmapDecoder* decoder = NULL;
    IWICBitmapFrameDecode* frame = NULL;
    IWICFormatConverter* conv = NULL;

    if (SUCCEEDED(IWICImagingFactory_CreateStream(wic, &stream)) &&
        SUCCEEDED(IWICStream_InitializeFromMemory(
            stream, (BYTE*)data, (DWORD)len)) &&
        SUCCEEDED(IWICImagingFactory_CreateDecoderFromStream(
            wic, (IStream*)stream, NULL, WICDecodeMetadataCacheOnDemand, &decoder)) &&
        SUCCEEDED(IWICBitmapDecoder_GetFrame(decoder, 0, &frame)) &&
        SUCCEEDED(IWICImagingFactory_CreateFormatConverter(wic, &conv)) &&
        SUCCEEDED(IWICFormatConverter_Initialize(
            conv, (IWICBitmapSource*)frame, &GUID_WICPixelFormat32bppBGRA,
            WICBitmapDitherTypeNone, NULL, 0.0, WICBitmapPaletteTypeCustom))) {
        UINT width = 0, height = 0;
        IWICFormatConverter_GetSize(conv, &width, &height);
        if (width > 0 && height > 0) {
            UINT stride = width * 4;
            UINT image_bytes = stride * height;
            SIZE_T total = sizeof(BITMAPINFOHEADER) + image_bytes;
            HGLOBAL hg = GlobalAlloc(GMEM_MOVEABLE, total);
            if (hg) {
                uint8_t* mem = (uint8_t*)GlobalLock(hg);
                BITMAPINFOHEADER* bih = (BITMAPINFOHEADER*)mem;
                memset(bih, 0, sizeof(*bih));
                bih->biSize = sizeof(BITMAPINFOHEADER);
                bih->biWidth = (LONG)width;
                bih->biHeight = (LONG)height; // bottom-up
                bih->biPlanes = 1;
                bih->biBitCount = 32;
                bih->biCompression = BI_RGB;
                // WIC gives top-down rows; DIB wants bottom-up. Copy
                // row-reversed.
                uint8_t* pixels = mem + sizeof(BITMAPINFOHEADER);
                uint8_t* tmp = (uint8_t*)malloc(image_bytes);
                if (tmp && SUCCEEDED(IWICFormatConverter_CopyPixels(
                        conv, NULL, stride, image_bytes, tmp))) {
                    for (UINT row = 0; row < height; row++) {
                        memcpy(pixels + (size_t)(height - 1 - row) * stride,
                               tmp + (size_t)row * stride, stride);
                    }
                    GlobalUnlock(hg);
                    if (cb_open()) {
                        EmptyClipboard();
                        ok = SetClipboardData(CF_DIB, hg) != NULL;
                        CloseClipboard();
                    }
                    if (!ok) GlobalFree(hg);
                } else {
                    GlobalUnlock(hg);
                    GlobalFree(hg);
                }
                free(tmp);
            }
        }
    }
    if (conv) IWICFormatConverter_Release(conv);
    if (frame) IWICBitmapFrameDecode_Release(frame);
    if (decoder) IWICBitmapDecoder_Release(decoder);
    if (stream) IWICStream_Release(stream);
    return ok;
}

char* windows_clipboard_read_image_png_b64(void) {
    uint8_t* png = NULL;
    int32_t len = 0;
    if (!cb_read_image_png(&png, &len)) return NULL;
    DWORD b64_len = 0;
    char* b64 = NULL;
    if (CryptBinaryToStringA(png, (DWORD)len,
            CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, NULL, &b64_len)) {
        b64 = (char*)malloc(b64_len + 1);
        if (b64 && !CryptBinaryToStringA(png, (DWORD)len,
                CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, b64, &b64_len)) {
            free(b64);
            b64 = NULL;
        }
        if (b64) b64[b64_len] = '\0';
    }
    free(png);
    return b64;
}

bool windows_clipboard_write_image_png_b64(const char* b64) {
    if (!b64 || !b64[0]) return false;
    DWORD bin_len = 0;
    if (!CryptStringToBinaryA(b64, 0, CRYPT_STRING_BASE64, NULL, &bin_len, NULL, NULL)) {
        return false;
    }
    uint8_t* bin = (uint8_t*)malloc(bin_len);
    if (!bin) return false;
    bool ok = false;
    if (CryptStringToBinaryA(b64, 0, CRYPT_STRING_BASE64, bin, &bin_len, NULL, NULL)) {
        ok = cb_write_image_png(bin, (int32_t)bin_len);
    }
    free(bin);
    return ok;
}

// --- Presence + clear ---

bool windows_clipboard_has(const char* fmt) {
    if (!fmt) return false;
    if (strcmp(fmt, "text") == 0) {
        return IsClipboardFormatAvailable(CF_UNICODETEXT) ||
               IsClipboardFormatAvailable(CF_TEXT);
    }
    if (strcmp(fmt, "html") == 0) {
        return IsClipboardFormatAvailable(cb_html_format());
    }
    if (strcmp(fmt, "image") == 0) {
        return IsClipboardFormatAvailable(CF_BITMAP) ||
               IsClipboardFormatAvailable(CF_DIB);
    }
    if (strcmp(fmt, "files") == 0) {
        return IsClipboardFormatAvailable(CF_HDROP);
    }
    return false;
}

void windows_clipboard_clear(void) {
    if (!cb_open()) return;
    EmptyClipboard();
    CloseClipboard();
}
