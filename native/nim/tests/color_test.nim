import ../color
import std/options
import std/colors

# Helper: parse to an unnamed 4-tuple (avoids named/unnamed tuple == ambiguity).
proc rgba(s: string): (int, int, int, int) =
  let p = parseCssColor(s).get
  (p.r, p.g, p.b, p.a)

# names (via std/colors)
doAssert rgba("blue") == (0, 0, 255, 255)
doAssert rgba("rebeccapurple") == (102, 51, 153, 255)
doAssert rgba("  BLUE  ") == (0, 0, 255, 255)          # whitespace + case tolerant

# hex: 3 / 6 / 8 digit
doAssert rgba("#00f") == (0, 0, 255, 255)
doAssert rgba("#0000ff") == (0, 0, 255, 255)
doAssert rgba("#0000FF80") == (0, 0, 255, 128)         # 8-digit alpha (case tolerant)

# rgb() / rgba()
doAssert rgba("rgb(1,2,3)") == (1, 2, 3, 255)
doAssert rgba("rgb( 10 , 20 , 30 )") == (10, 20, 30, 255)   # inner whitespace
doAssert rgba("rgba(0,0,0,0.5)") == (0, 0, 0, 128)
doAssert rgba("rgba(0,0,0,1)") == (0, 0, 0, 255)            # alpha 1 = opaque

# invalid → none
doAssert parseCssColor("").isNone                # empty
doAssert parseCssColor("#zz").isNone             # non-hex
doAssert parseCssColor("#1234567").isNone        # bad hex length (7)
doAssert parseCssColor("reddish").isNone         # unknown name
doAssert parseCssColor("rgb(1,2)").isNone        # wrong arity
doAssert parseCssColor("rgb(300,0,0)").isNone    # channel > 255
doAssert parseCssColor("rgba(0,0,0,2)").isNone   # alpha > 1
doAssert parseCssColor("rgba(0,0,0,128)").isNone # int alpha rejected (use #rrggbbaa)

# ZappColor converters
let zc: ZappColor = colBlue            # Color -> ZappColor ($Color is UPPERCASE hex)
doAssert string(zc) == "#0000FF"
let zs: ZappColor = "rebeccapurple"    # string -> ZappColor (identity wrap)
doAssert string(zs) == "rebeccapurple"

echo "color ok"
