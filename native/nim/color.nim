## CSS-style color parsing for window/sidebar/inspector backgroundColor.
## Accepts: CSS names + #rgb/#rrggbb/#rrggbbaa + rgb()/rgba(). Names come from
## std/colors; rgb()/rgba() and hex are parsed here (std/colors is RGB-only and
## doesn't parse rgb()/rgba()). rgba() alpha is a float in 0..1.

import std/options
import std/colors
import std/strutils

type ZappColor* = distinct string
  ## A backgroundColor value. Accepts a CSS string OR a std/colors `Color`
  ## (e.g. `colBlue`) via the converters below. The raw string is carried to
  ## native unchanged; native delegates parsing to `zapp_color_parse`.

converter toZappColor*(s: string): ZappColor = ZappColor(s)
converter colorToZappColor*(c: Color): ZappColor = ZappColor($c)  # $Color -> "#RRGGBB" (uppercase)

# stderr warn idiom (matches permissions.nim / worker.nim).
proc c_fprintf(stream: pointer, fmt: cstring) {.importc: "fprintf", varargs, header: "<stdio.h>", cdecl.}
var cstderr {.importc: "stderr", header: "<stdio.h>".}: pointer

proc parseHexPair(s: string): Option[int] =
  ## Parse exactly two hex digits (00..FF). None on any non-hex char.
  try: some(parseHexInt(s)) except ValueError: none(int)

proc parseHex(t: string): Option[tuple[r, g, b, a: int]] =
  ## t includes the leading '#'. Supports #rgb, #rrggbb, #rrggbbaa.
  let h = t[1 .. ^1]
  var rs, gs, bs, asx: string
  case h.len
  of 3:
    rs = $h[0] & $h[0]; gs = $h[1] & $h[1]; bs = $h[2] & $h[2]; asx = "ff"
  of 6:
    rs = h[0 .. 1]; gs = h[2 .. 3]; bs = h[4 .. 5]; asx = "ff"
  of 8:
    rs = h[0 .. 1]; gs = h[2 .. 3]; bs = h[4 .. 5]; asx = h[6 .. 7]
  else:
    return none(tuple[r, g, b, a: int])
  let r = parseHexPair(rs); let g = parseHexPair(gs)
  let b = parseHexPair(bs); let a = parseHexPair(asx)
  if r.isNone or g.isNone or b.isNone or a.isNone:
    return none(tuple[r, g, b, a: int])
  some((r.get, g.get, b.get, a.get))

proc parseRgbFunc(low: string): Option[tuple[r, g, b, a: int]] =
  ## low is the already-lowercased, already-trimmed string starting with
  ## "rgb(" or "rgba(". rgba alpha is a float 0..1.
  let isRgba = low.startsWith("rgba(")
  let openLen = if isRgba: 5 else: 4
  if not low.endsWith(")"):
    return none(tuple[r, g, b, a: int])
  let body = low[openLen .. ^2]              # drop "rgb("/"rgba(" and trailing ")"
  let parts = body.split(',')
  let wantArity = if isRgba: 4 else: 3
  if parts.len != wantArity:
    return none(tuple[r, g, b, a: int])
  var ch: array[3, int]
  for i in 0 .. 2:
    try:
      ch[i] = parseInt(parts[i].strip())
    except ValueError:
      return none(tuple[r, g, b, a: int])
    if ch[i] < 0 or ch[i] > 255:
      return none(tuple[r, g, b, a: int])
  var a = 255
  if isRgba:
    var f: float
    try:
      f = parseFloat(parts[3].strip())
    except ValueError:
      return none(tuple[r, g, b, a: int])
    if not (f >= 0.0 and f <= 1.0):          # rejects nan/inf too (NaN compares false)
      return none(tuple[r, g, b, a: int])
    a = int(f * 255.0 + 0.5)                 # round to nearest
  some((ch[0], ch[1], ch[2], a))

proc parseCssColor*(s: string): Option[tuple[r, g, b, a: int]] =
  ## Parse a CSS color: name | #rgb/#rrggbb/#rrggbbaa | rgb()/rgba().
  ## Returns none on empty or unparseable input.
  let t = s.strip()
  if t.len == 0:
    return none(tuple[r, g, b, a: int])
  let low = t.toLowerAscii()
  if low.startsWith("rgb(") or low.startsWith("rgba("):
    return parseRgbFunc(low)
  if t.startsWith("#"):
    return parseHex(t)
  try:
    let (r, g, b) = extractRGB(parseColor(low))
    some((int(r), int(g), int(b), 255))
  except ValueError:
    none(tuple[r, g, b, a: int])

proc zapp_color_parse*(s: cstring; r, g, b, a: ptr cint): bool {.exportc, cdecl.} =
  ## C-ABI entry called from native. Fills *r,*g,*b,*a (0..255) and returns true
  ## on success. Empty/nil => false (silent). Non-empty unparseable => warn + false.
  if s == nil: return false
  let str = $s
  if str.len == 0: return false
  let parsed = parseCssColor(str)
  if parsed.isNone:
    c_fprintf(cstderr, cstring("[zapp] invalid backgroundColor: \"%s\" — ignoring\n"), s)
    return false
  let (rr, gg, bb, aa) = parsed.get
  r[] = rr.cint; g[] = gg.cint; b[] = bb.cint; a[] = aa.cint
  true
