import illwave as iw
import colors, math, strutils, random

type
  ThemeMode* = enum tmDark, tmLight

  Theme* = object
    rosewater*, flamingo*, pink*, mauve*, red*, maroon*: colors.Color
    peach*, yellow*, green*, teal*, sky*, sapphire*, blue*, lavender*: colors.Color
    text*, subtext1*, subtext0*, overlay2*, overlay1*, overlay0*: colors.Color
    surface2*, surface1*, surface0*, base*, mantle*, crust*: colors.Color
    baseHue*: float

proc c(r, g, b: uint8): colors.Color {.inline.} =
  iw.toColor(r, g, b)

proc hashToInt(s: string): int =
  var h: int = 0
  for c in s:
    h = h *% 31 +% c.ord
  result = h and 0x7FFFFFFF

proc hslToRgb(h, s, l: float): (uint8, uint8, uint8) =
  let hp = h / 60.0
  let c = (1.0 - abs(2.0 * l - 1.0)) * s
  let x = c * (1.0 - abs(hp mod 2.0 - 1.0))
  let m = l - c / 2.0
  let (r1, g1, b1) =
    if hp < 1.0: (c, x, 0.0)
    elif hp < 2.0: (x, c, 0.0)
    elif hp < 3.0: (0.0, c, x)
    elif hp < 4.0: (0.0, x, c)
    elif hp < 5.0: (x, 0.0, c)
    else: (c, 0.0, x)
  let rf = max(0.0, min(255.0, (r1 + m) * 255.0))
  let gf = max(0.0, min(255.0, (g1 + m) * 255.0))
  let bf = max(0.0, min(255.0, (b1 + m) * 255.0))
  (rf.uint8, gf.uint8, bf.uint8)

proc genColor(h, s, l: float): colors.Color =
  let (r, g, b) = hslToRgb(h, s, l)
  c(r, g, b)

const
  ACCENT_HUE_OFFSETS = [330.0, 345.0, 300.0, 270.0, 0.0, 15.0, 30.0, 45.0,
                        120.0, 150.0, 180.0, 195.0, 210.0, 240.0]

proc generateTheme*(seed: string, mode: ThemeMode, refreshSeed: bool): Theme =
  var hval = hashToInt(seed)
  if refreshSeed:
    randomize()
    hval = rand(high(int))
  let baseHue = float(hval mod 360)
  let dark = mode == tmDark

  let accentSat = if dark: 0.75 else: 0.60
  let accentLight = if dark: 0.60 else: 0.50
  let accentColors: array[14, colors.Color] = block:
    var arr: array[14, colors.Color]
    for i, off in ACCENT_HUE_OFFSETS:
      let h = (baseHue + off) mod 360.0
      arr[i] = genColor(h, accentSat, accentLight)
    arr

  let textVal = if dark: 0.90 else: 0.25
  let sub1Val = if dark: 0.78 else: 0.35
  let sub0Val = if dark: 0.68 else: 0.45
  let ov2Val = if dark: 0.58 else: 0.52
  let ov1Val = if dark: 0.48 else: 0.60
  let ov0Val = if dark: 0.40 else: 0.68

  let baseH = (baseHue + 0.0) mod 360.0
  let bgSat = if dark: 0.10 else: 0.05

  let crustL = if dark: 0.06 else: 0.88
  let mantleL = if dark: 0.10 else: 0.92
  let baseL = if dark: 0.14 else: 0.95
  let surf0L = if dark: 0.20 else: 0.82
  let surf1L = if dark: 0.26 else: 0.78
  let surf2L = if dark: 0.32 else: 0.72

  let textH = baseH
  let subH = (baseH + 30.0) mod 360.0

  result = Theme(
    baseHue: baseHue,
    rosewater: accentColors[0], flamingo: accentColors[1],
    pink: accentColors[2], mauve: accentColors[3],
    red: accentColors[4], maroon: accentColors[5],
    peach: accentColors[6], yellow: accentColors[7],
    green: accentColors[8], teal: accentColors[9],
    sky: accentColors[10], sapphire: accentColors[11],
    blue: accentColors[12], lavender: accentColors[13],
    text: genColor(textH, 0.10, textVal),
    subtext1: genColor(subH, 0.08, sub1Val),
    subtext0: genColor(subH, 0.06, sub0Val),
    overlay2: genColor(subH, 0.05, ov2Val),
    overlay1: genColor(subH, 0.04, ov1Val),
    overlay0: genColor(subH, 0.03, ov0Val),
    surface2: genColor(baseH, bgSat * 1.2, surf2L),
    surface1: genColor(baseH, bgSat * 0.9, surf1L),
    surface0: genColor(baseH, bgSat * 0.7, surf0L),
    base: genColor(baseH, bgSat * 0.5, baseL),
    mantle: genColor(baseH, bgSat * 0.3, mantleL),
    crust: genColor(baseH, bgSat * 0.1, crustL)
  )

proc generateTheme*(seed: string, mode: ThemeMode): Theme =
  generateTheme(seed, mode, false)

proc getTheme*(flavor: string): Theme =
  generateTheme(flavor, tmDark, false)

proc isDarkMode*(seed: string): bool =
  let lower = seed.toLowerAscii()
  lower.contains("light") or lower.contains("latte")

proc getTheme*(seed: string, refreshEachLaunch: bool): Theme =
  let dark = not isDarkMode(seed)
  let mode = if dark: tmDark else: tmLight
  generateTheme(seed, mode, refreshEachLaunch)

proc parseThemeFlavor*(name: string): string =
  let lower = name.toLowerAscii().strip()
  if lower.len == 0: "mocha"
  else: lower

proc themeName*(seed: string): string =
  let parts = seed.split({'-', '_'})
  var named = true
  for p in parts:
    try:
      discard parseInt(p)
      named = false
    except: discard
  if named:
    var outParts: seq[string] = @[]
    for p in parts:
      if p.len > 0: outParts.add(p.capitalizeAscii())
    result = outParts.join(" ")
  else:
    result = "Custom Theme"
