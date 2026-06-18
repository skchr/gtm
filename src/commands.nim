## Command dispatch: fuzzy matching, keycode parsing, and action routing
##
## Provides utility functions used by the TUI's keybinding system.
## Commands themselves are registered via state.registerCommand() in gtm.nim
## and dispatched by string ID through the main event loop.
##
## ┌───────────────────────────────────────────────┐
## │  Keybinding flow                              │
## │                                               │
## │  keypress ──► parseKeyCode()                  │
## │      │                                        │
## │      ▼                                        │
## │  keybinding lookup (state.keybindings table)  │
## │      │                                        │
## │      ▼                                        │
## │  command string ID → executeCommand()         │
## │  (registered via state.registerCommand())     │
## │      │                                        │
## │      ├── TUI actions (nav, play/stop/seek,    │
## │      │   tab switch, filter, etc.)            │
## │      ├── IPC send (play, volume, shuffle,     │
## │      │   repeat, crossfade, etc.)             │
## │      └── Modal (command palette, fuzzy        │
## │          finder, queue picker)                │
## └───────────────────────────────────────────────┘

import illwave as iw
import state, strutils, sequtils, tables

proc fuzzyMatch*(query, target: string): bool =
  if query.len == 0: return true
  var qi = 0
  for tc in target:
    if qi < query.len and tc.toLowerAscii() == query[qi].toLowerAscii():
      qi.inc
    if qi == query.len: return true
  return false

{.push warning[HoleEnumConv]:off.}
proc parseKeyCode*(name: string): iw.Key =
  case name
  of "Space": iw.Key.Space
  of "Enter": iw.Key.Enter
  of "Escape": iw.Key.Escape
  of "Tab": iw.Key.Tab
  of "Backspace": iw.Key.Backspace
  of "Up": iw.Key.Up
  of "Down": iw.Key.Down
  of "Left": iw.Key.Left
  of "Right": iw.Key.Right
  of "Home": iw.Key.Home
  of "End": iw.Key.End
  of "PageUp": iw.Key.PageUp
  of "PageDown": iw.Key.PageDown
  of "Insert": iw.Key.Insert
  of "Delete": iw.Key.Delete
  of "Slash": iw.Key.Slash
  of "QuestionMark": iw.Key.QuestionMark
  of "Semicolon": iw.Key.Semicolon
  of "Colon": iw.Key.Colon
  of "Comma": iw.Key.Comma
  of "Dot": iw.Key.Dot
  of "Plus": iw.Key.Plus
  of "Equals": iw.Key.Equals
  of "Minus": iw.Key.Minus
  of "Underscore": iw.Key.Underscore
  of "Backslash": iw.Key.Backslash
  of "LeftBracket": iw.Key.LeftBracket
  of "RightBracket": iw.Key.RightBracket
  of "GraveAccent": iw.Key.GraveAccent
  of "Tilde": iw.Key.Tilde
  of "ExclamationMark": iw.Key.ExclamationMark
  of "Ampersand": iw.Key.Ampersand
  of "Pipe": iw.Key.Pipe
  of "At": iw.Key.At
  of "Hash": iw.Key.Hash
  of "Dollar": iw.Key.Dollar
  of "Percent": iw.Key.Percent
  of "Asterisk": iw.Key.Asterisk
  of "LeftParen": iw.Key.LeftParen
  of "RightParen": iw.Key.RightParen
  of "Zero": iw.Key.Zero
  of "One": iw.Key.One
  of "Two": iw.Key.Two
  of "Three": iw.Key.Three
  of "Four": iw.Key.Four
  of "Five": iw.Key.Five
  of "Six": iw.Key.Six
  of "Seven": iw.Key.Seven
  of "Eight": iw.Key.Eight
  of "Nine": iw.Key.Nine
  of "F1": iw.Key.F1
  of "F2": iw.Key.F2
  of "F3": iw.Key.F3
  of "F4": iw.Key.F4
  of "F5": iw.Key.F5
  of "F6": iw.Key.F6
  of "F7": iw.Key.F7
  of "F8": iw.Key.F8
  of "F9": iw.Key.F9
  of "F10": iw.Key.F10
  of "F11": iw.Key.F11
  of "F12": iw.Key.F12
  of "CtrlBackslash": iw.Key.CtrlBackslash
  of "CtrlRightBracket": iw.Key.CtrlRightBracket
  of "LessThan": iw.Key.LessThan
  of "GreaterThan": iw.Key.GreaterThan
  of "SingleQuote": iw.Key.SingleQuote
  of "DoubleQuote": iw.Key.DoubleQuote
  of "LeftBrace": iw.Key.LeftBrace
  of "RightBrace": iw.Key.RightBrace
  of "Caret": iw.Key.Caret
  else:
    if name.len == 1:
      let c = name[0]
      if c in {'a'..'z'}:
        iw.Key(ord(iw.Key.A) + (c.ord - 'a'.ord))
      elif c in {'A'..'Z'}:
        iw.Key(ord(iw.Key.ShiftA) + (c.ord - 'A'.ord))
      elif c in {'0'..'9'}:
        iw.Key(ord(iw.Key.Zero) + (c.ord - '0'.ord))
      else:
        iw.Key.None
    elif name.startsWith("Shift") and name.len > 5:
      let c = name[5]
      if c in {'A'..'Z'}:
        iw.Key(ord(iw.Key.ShiftA) + (c.ord - 'A'.ord))
      else:
        iw.Key.None
    elif name.startsWith("Ctrl") and name.len > 4:
      let c = name[4]
      if c in {'A'..'Z'}:
        iw.Key(ord(iw.Key.CtrlA) + (c.ord - 'A'.ord))
      else:
        iw.Key.None
    elif name.startsWith("Alt") and name.len > 3:
      let c = name[3]
      if c in {'A'..'Z'}:
        iw.Key(ord(iw.Key.AltA) + (c.ord - 'A'.ord))
      else:
        iw.Key.None
    else:
      iw.Key.None
{.pop.}

proc keyDisplayName*(key: iw.Key): string =
  case key
  of iw.Key.Space: "Space"
  of iw.Key.Enter: "Enter"
  of iw.Key.Escape: "Esc"
  of iw.Key.Tab: "Tab"
  of iw.Key.Backspace: "Bksp"
  of iw.Key.Up: "Up"
  of iw.Key.Down: "Down"
  of iw.Key.Left: "Left"
  of iw.Key.Right: "Right"
  of iw.Key.Home: "Home"
  of iw.Key.End: "End"
  of iw.Key.PageUp: "PgUp"
  of iw.Key.PageDown: "PgDn"
  of iw.Key.Insert: "Ins"
  of iw.Key.Delete: "Del"
  of iw.Key.Slash: "/"
  of iw.Key.QuestionMark: "?"
  of iw.Key.Colon: ":"
  of iw.Key.Semicolon: ";"
  of iw.Key.Comma: ","
  of iw.Key.Dot: "."
  of iw.Key.Plus: "+"
  of iw.Key.Equals: "="
  of iw.Key.Minus: "-"
  of iw.Key.Underscore: "_"
  of iw.Key.Zero: "0"
  of iw.Key.One: "1"
  of iw.Key.Two: "2"
  of iw.Key.Three: "3"
  of iw.Key.Four: "4"
  of iw.Key.Five: "5"
  of iw.Key.Six: "6"
  of iw.Key.Seven: "7"
  of iw.Key.Eight: "8"
  of iw.Key.Nine: "9"

  else:
    let ordv = key.ord
    if ordv >= ord(iw.Key.A) and ordv <= ord(iw.Key.Z):
      $char(ordv)
    elif ordv >= ord(iw.Key.ShiftA) and ordv <= ord(iw.Key.ShiftZ):
      "Shift+" & $char(ordv - ord(iw.Key.ShiftA) + ord('A'))
    elif ordv >= ord(iw.Key.CtrlA) and ordv <= ord(iw.Key.CtrlZ):
      "Ctrl+" & $char(ordv - ord(iw.Key.CtrlA) + ord('A'))
    elif ordv >= ord(iw.Key.AltA) and ordv <= ord(iw.Key.AltZ):
      "Alt+" & $char(ordv - ord(iw.Key.AltA) + ord('A'))
    elif ordv >= ord(iw.Key.F1) and ordv <= ord(iw.Key.F12):
      "F" & $(ordv - ord(iw.Key.F1) + 1)
    else:
      "?"

proc bindingDisplay*(keys: seq[iw.Key]): string =
  keys.mapIt(keyDisplayName(it)).join(",")

proc registerCommand*(state: var AppState, id, name, description, icon: string,
                      defaultKeys: seq[string], handler: proc(state: var AppState)) =
  var parsed: seq[seq[iw.Key]] = @[]
  for dk in defaultKeys:
    if '+' in dk:
      parsed.add(dk.split('+').mapIt(parseKeyCode(it.strip())))
    else:
      let k = parseKeyCode(dk)
      if k != iw.Key.None:
        parsed.add(@[k])
  let entry = CommandEntry(
    id: id, name: name, description: description,
    icon: icon, defaultKeys: defaultKeys,
    keyCodes: @[], handler: handler)
  state.commands.add(entry)
  let idx = state.commands.len - 1
  state.cmdRegistry[id] = idx
  state.commands[idx].keyCodes = parsed
  state.keybindings[id] = id
  for seq in parsed:
    if seq.len == 1:
      let key = seq[0]
      if not state.keyDispatch.hasKey(key):
        state.keyDispatch[key] = @[]
      state.keyDispatch[key].add(idx)
    elif seq.len > 1:
      state.multiKeyDispatch[seq] = idx
      let firstKey = seq[0]
      if not state.keyDispatch.hasKey(firstKey):
        state.keyDispatch[firstKey] = @[]
      if idx notin state.keyDispatch[firstKey]:
        state.keyDispatch[firstKey].add(idx)

proc findCommandIdx*(state: AppState, id: string): int =
  if state.cmdRegistry.hasKey(id):
    return state.cmdRegistry[id]
  -1

proc rebindCommand*(state: var AppState, id: string, newKeys: seq[string]) =
  let idx = state.findCommandIdx(id)
  if idx < 0: return
  let oldParsed = state.commands[idx].keyCodes
  # Remove old dispatch entries
  for seq in oldParsed:
    if seq.len == 1:
      let key = seq[0]
      if state.keyDispatch.hasKey(key):
        state.keyDispatch[key].keepItIf(it != idx)
        if state.keyDispatch[key].len == 0:
          state.keyDispatch.del(key)
    elif seq.len > 1:
      state.multiKeyDispatch.del(seq)
      let firstKey = seq[0]
      if state.keyDispatch.hasKey(firstKey):
        state.keyDispatch[firstKey].keepItIf(it != idx)
        if state.keyDispatch[firstKey].len == 0:
          state.keyDispatch.del(firstKey)
  # Parse and add new dispatch entries
  var parsed: seq[seq[iw.Key]] = @[]
  for dk in newKeys:
    if '+' in dk:
      parsed.add(dk.split('+').mapIt(parseKeyCode(it.strip())))
    else:
      let k = parseKeyCode(dk)
      if k != iw.Key.None:
        parsed.add(@[k])
  state.commands[idx].keyCodes = parsed
  state.commands[idx].defaultKeys = newKeys
  state.keybindings[id] = newKeys.join(", ")
  for seq in parsed:
    if seq.len == 1:
      let key = seq[0]
      if not state.keyDispatch.hasKey(key):
        state.keyDispatch[key] = @[]
      state.keyDispatch[key].add(idx)
    elif seq.len > 1:
      state.multiKeyDispatch[seq] = idx
      let firstKey = seq[0]
      if not state.keyDispatch.hasKey(firstKey):
        state.keyDispatch[firstKey] = @[]
      if idx notin state.keyDispatch[firstKey]:
        state.keyDispatch[firstKey].add(idx)


