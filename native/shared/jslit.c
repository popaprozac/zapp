#include "jslit.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

char* zapp_js_lit_dup(const char* utf8) {
  if (utf8 == NULL) utf8 = "";
  size_t n = strlen(utf8);
  /* worst case: every byte -> \u00XX (6) ; + 2 quotes + NUL */
  char* out = (char*)malloc(n * 6 + 3);
  if (out == NULL) return NULL;
  size_t j = 0;
  out[j++] = '"';
  for (size_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)utf8[i];
    switch (c) {
      case '"':  out[j++]='\\'; out[j++]='"';  break;
      case '\\': out[j++]='\\'; out[j++]='\\'; break;
      case '\b': out[j++]='\\'; out[j++]='b';  break;
      case '\f': out[j++]='\\'; out[j++]='f';  break;
      case '\n': out[j++]='\\'; out[j++]='n';  break;
      case '\r': out[j++]='\\'; out[j++]='r';  break;
      case '\t': out[j++]='\\'; out[j++]='t';  break;
      default:
        if (c < 0x20) {
          out[j++]='\\'; out[j++]='u'; out[j++]='0'; out[j++]='0';
          static const char* hex = "0123456789abcdef";
          out[j++] = hex[(c >> 4) & 0xF];
          out[j++] = hex[c & 0xF];
        } else if (c == 0xE2 && i + 2 < n &&
                   (unsigned char)utf8[i+1] == 0x80 &&
                   ((unsigned char)utf8[i+2] == 0xA8 || (unsigned char)utf8[i+2] == 0xA9)) {
          /* U+2028 (E2 80 A8) / U+2029 (E2 80 A9) — legal in JSON, ILLEGAL raw in a JS string */
          const char* esc = ((unsigned char)utf8[i+2] == 0xA8) ? "\\u2028" : "\\u2029";
          memcpy(out + j, esc, 6); j += 6; i += 2;
        } else {
          out[j++] = (char)c;  /* pass UTF-8 through verbatim */
        }
    }
  }
  out[j++] = '"';
  out[j]   = '\0';
  return out;
}
