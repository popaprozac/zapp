#ifndef ZAPP_JSLIT_H
#define ZAPP_JSLIT_H
/* Encode a UTF-8 C string as a COMPLETE double-quoted JavaScript string literal
 * (quotes included) that evals back to exactly the input. malloc'd; caller
 * free()s. NULL only on malloc failure. Never fails on content. */
char* zapp_js_lit_dup(const char* utf8);
#endif
