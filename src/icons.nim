import os, strutils

type
  IconPack* = object
    play*, pause*, stop*, nextTrack*, prevTrack*: string
    volumeHigh*, volumeMedium*, volumeLow*, volumeMuted*: string
    music*, artist*, album*, playlist*: string
    search*, heart*, shuffle*, repeatOne*, repeatAll*: string
    queue*, library*, settings*, help*: string
    checkmark*, cross*, arrowUp*, arrowDown*, arrowLeft*, arrowRight*: string
    musicNote*, disk*, headphone*, speaker*: string
    commandPalette*, filter*, selectMode*: string
    track*, time*, folder*, file*: string

proc nerdFontIcons*(): IconPack =
  IconPack(
    play: "\uF04B", pause: "\uF04C", stop: "\uF04D",
    nextTrack: "\uF050", prevTrack: "\uF049",
    volumeHigh: "\uF028", volumeMedium: "\uF027", volumeLow: "\uF026", volumeMuted: "\uF6A9",
    music: "\uF001", artist: "\uF007", album: "\uF0A0", playlist: "\uF0CA",
    search: "\uF002", heart: "\uF004", shuffle: "\uF049D", repeatOne: "\uF0B6", repeatAll: "\uF01E",
    queue: "\uF0C9", library: "\uF02D", settings: "\uF013", help: "\uF059",
    checkmark: "\uF00C", cross: "\uF00D", arrowUp: "\uF062", arrowDown: "\uF063", arrowLeft: "\uF060", arrowRight: "\uF061",
    musicNote: "\uF3B5", disk: "\uF0A0", headphone: "\uF025", speaker: "\uF028",
    commandPalette: "\uF120", filter: "\uF0B0", selectMode: "\uF204",
    track: "\uF001", time: "\uF017", folder: "\uF07B", file: "\uF15B"
  )

proc emojiIcons*(): IconPack =
  IconPack(
    play: "\u25B6", pause: "\u23F8", stop: "\u23F9",
    nextTrack: "\u23ED", prevTrack: "\u23EE",
    volumeHigh: "\U0001F50A", volumeMedium: "\U0001F509", volumeLow: "\U0001F508", volumeMuted: "\U0001F507",
    music: "\U0001F3B5", artist: "\U0001F464", album: "\U0001F4BF", playlist: "\U0001F4CB",
    search: "\U0001F50D", heart: "\u2764", shuffle: "\U0001F500", repeatOne: "\U0001F502", repeatAll: "\U0001F501",
    queue: "\U0001F4DC", library: "\U0001F4DA", settings: "\u2699", help: "\u2753",
    checkmark: "\u2714", cross: "\u274C", arrowUp: "\u2B06", arrowDown: "\u2B07", arrowLeft: "\u2B05", arrowRight: "\u27A1",
    musicNote: "\u266B", disk: "\U0001F4BF", headphone: "\U0001F3A7", speaker: "\U0001F509",
    commandPalette: "\u2328", filter: "\U0001F50D", selectMode: "\U0001F7E8",
    track: "\U0001F3B5", time: "\u23F1", folder: "\U0001F4C1", file: "\U0001F4C4"
  )

var
  gNerdFontDetected*: bool = false
  gNerdDetectionDone: bool = false

proc detectNerdFonts*(): bool =
  if gNerdDetectionDone:
    return gNerdFontDetected
  gNerdDetectionDone = true

  let nfEnv = getEnv("NERD_FONTS", "")
  if nfEnv.len > 0:
    gNerdFontDetected = nfEnv == "1" or nfEnv.toLowerAscii() == "true"
    return gNerdFontDetected

  let termProg = getEnv("TERM_PROGRAM", "")
  if termProg.len > 0:
    let knownNerdTerms = ["alacritty", "kitty", "wezterm", "tabby", "warp",
                          "ghostty", "foot", "konsole", "hyper", "terminator",
                          "terminology", "tilix", "urxvt", "st"]
    if termProg.toLowerAscii() in knownNerdTerms:
      gNerdFontDetected = true
      return true

  let term = getEnv("TERM", "")
  if term.contains("kitty") or term.contains("alacritty") or
     term.contains("wezterm") or term.contains("foot") or
     term.contains("ghostty"):
    gNerdFontDetected = true
    return true

  gNerdFontDetected = false
  return false

proc currentIcons*(): IconPack =
  if detectNerdFonts():
    nerdFontIcons()
  else:
    emojiIcons()
