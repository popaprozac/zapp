// Zapp CEF host (macOS) — manual reference-counting macros for CEF C-API
// structs. Promoted verbatim from the proven `spikes/cef-macos/cef_refcount.h`
// GO spike (see docs/superpowers/specs/2026-07-05-cef-webengine-production-
// slice-macos-design.md) — only the header guard and identifier prefix
// changed (cefspike_ -> zapp_cef_ is not needed here; these macros take the
// struct/field names as arguments, so nothing internal to rename).
//
// Adapted verbatim-in-spirit from the CEF reference:
//   tests/cefsimple_capi/ref_counted.h
// (https://github.com/chromiumembedded/cef, BSD-licensed). Every cef_*_t Zapp
// implements embeds a cef_base_ref_counted_t as its first member and must
// provide atomic add_ref/release/has_one_ref/has_at_least_one_ref. These
// macros generate that boilerplate.

#ifndef ZAPP_CEF_REFCOUNT_H_
#define ZAPP_CEF_REFCOUNT_H_

#include <stdatomic.h>
#include <stdlib.h>

// Implement add_ref for a structure type.
#define IMPLEMENT_ADDREF(struct_type, struct_name, ref_field)             \
  void CEF_CALLBACK struct_name##_add_ref(cef_base_ref_counted_t* self) { \
    struct_type* obj = (struct_type*)self;                                \
    atomic_fetch_add(&obj->ref_field, 1);                                 \
  }

// Implement has_one_ref for a structure type.
#define IMPLEMENT_HAS_ONE_REF(struct_type, struct_name, ref_field)           \
  int CEF_CALLBACK struct_name##_has_one_ref(cef_base_ref_counted_t* self) { \
    struct_type* obj = (struct_type*)self;                                   \
    return atomic_load(&obj->ref_field) == 1;                                \
  }

// Implement has_at_least_one_ref for a structure type.
#define IMPLEMENT_HAS_AT_LEAST_ONE_REF(struct_type, struct_name, ref_field) \
  int CEF_CALLBACK struct_name##_has_at_least_one_ref(                      \
      cef_base_ref_counted_t* self) {                                       \
    struct_type* obj = (struct_type*)self;                                  \
    return atomic_load(&obj->ref_field) >= 1;                               \
  }

// Simple release that only frees the object (no owned ref-counted members).
#define IMPLEMENT_RELEASE_SIMPLE(struct_type, struct_name, ref_field)    \
  int CEF_CALLBACK struct_name##_release(cef_base_ref_counted_t* self) { \
    struct_type* obj = (struct_type*)self;                               \
    int count = atomic_fetch_sub(&obj->ref_field, 1) - 1;                \
    if (count == 0) {                                                    \
      free(obj);                                                         \
      return 1;                                                          \
    }                                                                    \
    return 0;                                                            \
  }

// All ref-counting for structures needing only free() on the last release.
#define IMPLEMENT_REFCOUNTING_SIMPLE(struct_type, struct_name, ref_field) \
  IMPLEMENT_ADDREF(struct_type, struct_name, ref_field)                   \
  IMPLEMENT_RELEASE_SIMPLE(struct_type, struct_name, ref_field)           \
  IMPLEMENT_HAS_ONE_REF(struct_type, struct_name, ref_field)              \
  IMPLEMENT_HAS_AT_LEAST_ONE_REF(struct_type, struct_name, ref_field)

// Ref-counting WITHOUT release — for structures needing custom cleanup. The
// caller must hand-implement struct_name##_release().
#define IMPLEMENT_REFCOUNTING_MANUAL(struct_type, struct_name, ref_field) \
  IMPLEMENT_ADDREF(struct_type, struct_name, ref_field)                   \
  IMPLEMENT_HAS_ONE_REF(struct_type, struct_name, ref_field)              \
  IMPLEMENT_HAS_AT_LEAST_ONE_REF(struct_type, struct_name, ref_field)

// Initialize a CEF base ref-counted structure. Call after allocating.
#define INIT_CEF_BASE_REFCOUNTED(ptr, cef_type, struct_name)          \
  do {                                                                \
    (ptr)->size = sizeof(cef_type);                                   \
    (ptr)->add_ref = struct_name##_add_ref;                           \
    (ptr)->release = struct_name##_release;                           \
    (ptr)->has_one_ref = struct_name##_has_one_ref;                   \
    (ptr)->has_at_least_one_ref = struct_name##_has_at_least_one_ref; \
  } while (0)

#endif  // ZAPP_CEF_REFCOUNT_H_
