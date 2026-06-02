import os, strutils
import state, theme

when defined(useSqlite):
  {.compile: "vendor/sqlite/sqlite3.c".}
  {.passC: "-Ivendor/sqlite".}

  type
    sqlite3 = ptr object
    sqlite3_stmt = ptr object

  proc sqlite3_open(path: cstring; db: ptr sqlite3): cint {.importc, cdecl.}
  proc sqlite3_close(db: sqlite3): cint {.importc, cdecl.}
  proc sqlite3_exec(db: sqlite3; sql: cstring; cb: pointer; arg: pointer; err: ptr cstring): cint {.importc, cdecl.}
  proc sqlite3_prepare_v2(db: sqlite3; sql: cstring; n: cint; stmt: ptr sqlite3_stmt; tail: ptr cstring): cint {.importc, cdecl.}
  proc sqlite3_step(stmt: sqlite3_stmt): cint {.importc, cdecl.}
  proc sqlite3_finalize(stmt: sqlite3_stmt): cint {.importc, cdecl.}
  proc sqlite3_bind_text(stmt: sqlite3_stmt; idx: cint; val: cstring; n: cint; destructor: pointer): cint {.importc, cdecl.}
  proc sqlite3_bind_int(stmt: sqlite3_stmt; idx: cint; val: cint): cint {.importc, cdecl.}
  proc sqlite3_bind_int64(stmt: sqlite3_stmt; idx: cint; val: int64): cint {.importc, cdecl.}
  proc sqlite3_bind_double(stmt: sqlite3_stmt; idx: cint; val: cdouble): cint {.importc, cdecl.}
  proc sqlite3_column_type(stmt: sqlite3_stmt; i: cint): cint {.importc, cdecl.}
  proc sqlite3_column_text(stmt: sqlite3_stmt; i: cint): cstring {.importc, cdecl.}
  proc sqlite3_column_int(stmt: sqlite3_stmt; i: cint): cint {.importc, cdecl.}
  proc sqlite3_column_int64(stmt: sqlite3_stmt; i: cint): int64 {.importc, cdecl.}
  proc sqlite3_column_double(stmt: sqlite3_stmt; i: cint): cdouble {.importc, cdecl.}
  proc sqlite3_last_insert_rowid(db: sqlite3): int64 {.importc, cdecl.}
  proc sqlite3_errmsg(db: sqlite3): cstring {.importc, cdecl.}

  const
    SQLITE_OK = 0
    SQLITE_ROW = 100
    SQLITE_NULL = 5
    SQLITE_TRANSIENT = cast[pointer](-1)

  type
    LibraryDb* = ref object
      db: sqlite3

  proc sqlerror(db: sqlite3, msg: string) =
    stderr.writeLine("[sqlite3] " & msg & ": " & $sqlite3_errmsg(db))

  proc execRaw(db: sqlite3, sql: string): bool =
    if sqlite3_exec(db, sql.cstring, nil, nil, nil) != SQLITE_OK:
      sqlerror(db, "exec: " & sql)
      return false
    return true

  proc prepare(db: sqlite3, sql: string): sqlite3_stmt =
    var stmt: sqlite3_stmt
    if sqlite3_prepare_v2(db, sql.cstring, -1.cint, addr stmt, nil) != SQLITE_OK:
      sqlerror(db, "prepare: " & sql)
    result = stmt

  proc bindText(stmt: sqlite3_stmt, idx: cint, val: string) =
    discard sqlite3_bind_text(stmt, idx, val.cstring, -1.cint, SQLITE_TRANSIENT)

  proc bindInt(stmt: sqlite3_stmt, idx: cint, val: int) =
    discard sqlite3_bind_int(stmt, idx, val.cint)

  proc bindInt64(stmt: sqlite3_stmt, idx: cint, val: int64) =
    discard sqlite3_bind_int64(stmt, idx, val)

  proc bindDouble(stmt: sqlite3_stmt, idx: cint, val: float) =
    discard sqlite3_bind_double(stmt, idx, val.cdouble)

  proc colText(stmt: sqlite3_stmt, idx: cint): string =
    if sqlite3_column_type(stmt, idx) == SQLITE_NULL: ""
    else: $sqlite3_column_text(stmt, idx)

  proc colInt(stmt: sqlite3_stmt, idx: cint): int =
    if sqlite3_column_type(stmt, idx) == SQLITE_NULL: 0
    else: int(sqlite3_column_int(stmt, idx))

  proc colInt64(stmt: sqlite3_stmt, idx: cint): int64 =
    if sqlite3_column_type(stmt, idx) == SQLITE_NULL: 0
    else: sqlite3_column_int64(stmt, idx)

  proc colFloat(stmt: sqlite3_stmt, idx: cint): float =
    if sqlite3_column_type(stmt, idx) == SQLITE_NULL: 0.0
    else: float(sqlite3_column_double(stmt, idx))

  proc finalize(stmt: sqlite3_stmt) =
    discard sqlite3_finalize(stmt)

  proc execSql*(db: sqlite3, sql: string; params: varargs[string, `$`]) =
    let stmt = prepare(db, sql)
    if stmt == nil: return
    for i, p in params:
      bindText(stmt, cint(i + 1), p)
    discard sqlite3_step(stmt)
    finalize(stmt)

  proc execSqlI*(db: sqlite3, sql: string; params: varargs[string, `$`]) =
    let stmt = prepare(db, sql)
    if stmt == nil: return
    for i, p in params:
      bindText(stmt, cint(i + 1), p)
    discard sqlite3_step(stmt)
    finalize(stmt)

  proc openLibrary*(path: string): LibraryDb =
    let dir = path.parentDir()
    if not dirExists(dir):
      createDir(dir)
    result = LibraryDb()
    if sqlite3_open(path.cstring, addr result.db) != SQLITE_OK:
      sqlerror(result.db, "open")
      result = nil

  proc initSchema*(lib: LibraryDb) =
    discard execRaw(lib.db, """
      CREATE TABLE IF NOT EXISTS artists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT UNIQUE NOT NULL
      )
    """)
    discard execRaw(lib.db, """
      CREATE TABLE IF NOT EXISTS albums (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        artist_id INTEGER REFERENCES artists(id),
        year INTEGER DEFAULT 0,
        genre TEXT DEFAULT ''
      )
    """)
    discard execRaw(lib.db, """
      CREATE TABLE IF NOT EXISTS tracks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT UNIQUE NOT NULL,
        title TEXT DEFAULT '',
        artist_id INTEGER REFERENCES artists(id),
        album_id INTEGER REFERENCES albums(id),
        track_num INTEGER DEFAULT 0,
        duration REAL DEFAULT 0.0,
        year INTEGER DEFAULT 0,
        genre TEXT DEFAULT '',
        added_at TEXT DEFAULT (datetime('now')),
        play_count INTEGER DEFAULT 0,
        last_played TEXT
      )
    """)
    discard execRaw(lib.db, """
      CREATE TABLE IF NOT EXISTS playlists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        created_at TEXT DEFAULT (datetime('now'))
      )
    """)
    discard execRaw(lib.db, """
      CREATE TABLE IF NOT EXISTS playlist_tracks (
        playlist_id INTEGER REFERENCES playlists(id),
        track_id INTEGER REFERENCES tracks(id),
        position INTEGER,
        PRIMARY KEY(playlist_id, track_id)
      )
    """)
    discard execRaw(lib.db, """
      CREATE TABLE IF NOT EXISTS playback_state (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    """)

  proc getArtistId*(lib: LibraryDb, name: string): int64 =
    let adjusted = if name.len == 0: "Unknown Artist" else: name
    let stmt = prepare(lib.db, "SELECT id FROM artists WHERE name = ?")
    if stmt == nil: return 0
    bindText(stmt, 1.cint, adjusted)
    if sqlite3_step(stmt) == SQLITE_ROW:
      result = colInt64(stmt, 0.cint)
    else:
      discard execRaw(lib.db, "INSERT INTO artists (name) VALUES ('" & adjusted.replace("'", "''") & "')")
      result = sqlite3_last_insert_rowid(lib.db)
    finalize(stmt)

  proc getAlbumId*(lib: LibraryDb, title: string, artistId: int64, year: int, genre: string): int64 =
    let adjusted = if title.len == 0: "Unknown Album" else: title
    let stmt = prepare(lib.db, "SELECT id FROM albums WHERE title = ? AND artist_id = ?")
    if stmt == nil: return 0
    bindText(stmt, 1.cint, adjusted)
    bindInt64(stmt, 2.cint, artistId)
    if sqlite3_step(stmt) == SQLITE_ROW:
      result = colInt64(stmt, 0.cint)
    else:
      let ins = prepare(lib.db, "INSERT INTO albums (title, artist_id, year, genre) VALUES (?, ?, ?, ?)")
      if ins != nil:
        bindText(ins, 1.cint, adjusted)
        bindInt64(ins, 2.cint, artistId)
        bindInt(ins, 3.cint, year)
        bindText(ins, 4.cint, genre)
        discard sqlite3_step(ins)
        finalize(ins)
      result = sqlite3_last_insert_rowid(lib.db)
    finalize(stmt)

  proc addTrack*(lib: LibraryDb, path, title, artist, album: string, duration: float,
                 trackNum, year: int, genre: string): int64 =
    let stmt = prepare(lib.db, "SELECT id FROM tracks WHERE path = ?")
    if stmt == nil: return 0
    bindText(stmt, 1.cint, path)
    if sqlite3_step(stmt) == SQLITE_ROW:
      result = colInt64(stmt, 0.cint)
      finalize(stmt)
      let artistId = getArtistId(lib, artist)
      let albumId = getAlbumId(lib, album, artistId, year, genre)
      let up = prepare(lib.db, "UPDATE tracks SET title=?, artist_id=?, album_id=?, duration=?, track_num=?, year=?, genre=? WHERE id=?")
      if up != nil:
        bindText(up, 1.cint, title)
        bindInt64(up, 2.cint, artistId)
        bindInt64(up, 3.cint, albumId)
        bindDouble(up, 4.cint, duration)
        bindInt(up, 5.cint, trackNum)
        bindInt(up, 6.cint, year)
        bindText(up, 7.cint, genre)
        bindInt64(up, 8.cint, result)
        discard sqlite3_step(up)
        finalize(up)
    else:
      finalize(stmt)
      let artistId = getArtistId(lib, artist)
      let albumId = getAlbumId(lib, album, artistId, year, genre)
      let ins = prepare(lib.db, "INSERT INTO tracks (path, title, artist_id, album_id, track_num, duration, year, genre) VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
      if ins != nil:
        bindText(ins, 1.cint, path)
        bindText(ins, 2.cint, title)
        bindInt64(ins, 3.cint, artistId)
        bindInt64(ins, 4.cint, albumId)
        bindInt(ins, 5.cint, trackNum)
        bindDouble(ins, 6.cint, duration)
        bindInt(ins, 7.cint, year)
        bindText(ins, 8.cint, genre)
        discard sqlite3_step(ins)
        finalize(ins)
      result = sqlite3_last_insert_rowid(lib.db)

  proc loadTracks*(lib: LibraryDb): seq[Track] =
    let stmt = prepare(lib.db, """
      SELECT t.id, t.path, t.title, a.name, al.title, t.duration, t.track_num, t.year, t.genre, t.play_count, t.artist_id, t.album_id
      FROM tracks t
      LEFT JOIN artists a ON t.artist_id = a.id
      LEFT JOIN albums al ON t.album_id = al.id
      ORDER BY a.name, al.title, t.track_num
    """)
    if stmt == nil: return
    while sqlite3_step(stmt) == SQLITE_ROW:
      result.add(Track(
        id: colInt64(stmt, 0.cint), path: colText(stmt, 1.cint), title: colText(stmt, 2.cint),
        artist: colText(stmt, 3.cint), album: colText(stmt, 4.cint), duration: colFloat(stmt, 5.cint),
        trackNum: colInt(stmt, 6.cint), year: colInt(stmt, 7.cint),
        genre: colText(stmt, 8.cint), playCount: colInt(stmt, 9.cint),
        artistId: colInt64(stmt, 10.cint), albumId: colInt64(stmt, 11.cint)
      ))
    finalize(stmt)

  proc loadArtists*(lib: LibraryDb): seq[ArtistEnt] =
    let stmt = prepare(lib.db, "SELECT id, name FROM artists ORDER BY name")
    if stmt == nil: return
    while sqlite3_step(stmt) == SQLITE_ROW:
      result.add(ArtistEnt(id: colInt64(stmt, 0.cint), name: colText(stmt, 1.cint)))
    finalize(stmt)

  proc loadAlbums*(lib: LibraryDb): seq[AlbumEnt] =
    let stmt = prepare(lib.db, """
      SELECT al.id, al.title, al.artist_id, a.name, al.year, al.genre
      FROM albums al
      LEFT JOIN artists a ON al.artist_id = a.id
      ORDER BY a.name, al.year, al.title
    """)
    if stmt == nil: return
    while sqlite3_step(stmt) == SQLITE_ROW:
      result.add(AlbumEnt(
        id: colInt64(stmt, 0.cint), title: colText(stmt, 1.cint),
        artistId: colInt64(stmt, 2.cint), artistName: colText(stmt, 3.cint),
        year: colInt(stmt, 4.cint), genre: colText(stmt, 5.cint)
      ))
    finalize(stmt)

  proc loadPlaylists*(lib: LibraryDb): seq[UserPlaylist] =
    let pl = prepare(lib.db, "SELECT id, name FROM playlists ORDER BY name")
    if pl == nil: return
    while sqlite3_step(pl) == SQLITE_ROW:
      let plId = colInt64(pl, 0.cint)
      let plName = colText(pl, 1.cint)
      var trackIds: seq[int64] = @[]
      let tr = prepare(lib.db, "SELECT track_id FROM playlist_tracks WHERE playlist_id = ? ORDER BY position")
      if tr != nil:
        bindInt64(tr, 1.cint, plId)
        while sqlite3_step(tr) == SQLITE_ROW:
          trackIds.add(colInt64(tr, 0.cint))
        finalize(tr)
      result.add(UserPlaylist(id: plId, name: plName, trackIds: trackIds))
    finalize(pl)

  proc createPlaylist*(lib: LibraryDb, name: string): int64 =
    if name.len == 0: return 0
    discard execRaw(lib.db, "INSERT INTO playlists (name) VALUES ('" & name.replace("'", "''") & "')")
    result = sqlite3_last_insert_rowid(lib.db)

  proc addTrackToPlaylist*(lib: LibraryDb, playlistId, trackId: int64, position: int) =
    let stmt = prepare(lib.db, "INSERT OR IGNORE INTO playlist_tracks (playlist_id, track_id, position) VALUES (?, ?, ?)")
    if stmt == nil: return
    bindInt64(stmt, 1.cint, playlistId)
    bindInt64(stmt, 2.cint, trackId)
    bindInt(stmt, 3.cint, position)
    discard sqlite3_step(stmt)
    finalize(stmt)

  proc removeTrackFromPlaylist*(lib: LibraryDb, playlistId, trackId: int64) =
    let stmt = prepare(lib.db, "DELETE FROM playlist_tracks WHERE playlist_id = ? AND track_id = ?")
    if stmt == nil: return
    bindInt64(stmt, 1.cint, playlistId)
    bindInt64(stmt, 2.cint, trackId)
    discard sqlite3_step(stmt)
    finalize(stmt)

  proc deletePlaylist*(lib: LibraryDb, playlistId: int64) =
    let stmt1 = prepare(lib.db, "DELETE FROM playlist_tracks WHERE playlist_id = ?")
    if stmt1 != nil:
      bindInt64(stmt1, 1.cint, playlistId)
      discard sqlite3_step(stmt1)
      finalize(stmt1)
    discard execRaw(lib.db, "DELETE FROM playlists WHERE id = " & $playlistId)

  proc getPlaybackState*(lib: LibraryDb, key: string): string =
    let stmt = prepare(lib.db, "SELECT value FROM playback_state WHERE key = ?")
    if stmt == nil: return ""
    bindText(stmt, 1.cint, key)
    if sqlite3_step(stmt) == SQLITE_ROW:
      result = colText(stmt, 0.cint)
    finalize(stmt)

  proc setPlaybackState*(lib: LibraryDb, key, value: string) =
    let stmt = prepare(lib.db, "INSERT OR REPLACE INTO playback_state (key, value) VALUES (?, ?)")
    if stmt == nil: return
    bindText(stmt, 1.cint, key)
    bindText(stmt, 2.cint, value)
    discard sqlite3_step(stmt)
    finalize(stmt)

  proc updatePlayCount*(lib: LibraryDb, trackId: int64) =
    let stmt = prepare(lib.db, "UPDATE tracks SET play_count = play_count + 1, last_played = datetime('now') WHERE id = ?")
    if stmt == nil: return
    bindInt64(stmt, 1.cint, trackId)
    discard sqlite3_step(stmt)
    finalize(stmt)

  proc closeDb*(lib: LibraryDb) =
    if lib != nil and lib.db != nil:
      discard sqlite3_close(lib.db)

else:
  type LibraryDb* = ref object
    dummy: bool

  proc openLibrary*(path: string): LibraryDb = LibraryDb()
  proc initSchema*(lib: LibraryDb) = discard
  proc addTrack*(lib: LibraryDb, path, title, artist, album: string, duration: float,
                 trackNum, year: int, genre: string): int64 = 0
  proc loadTracks*(lib: LibraryDb): seq[Track] = @[]
  proc loadArtists*(lib: LibraryDb): seq[ArtistEnt] = @[]
  proc loadAlbums*(lib: LibraryDb): seq[AlbumEnt] = @[]
  proc loadPlaylists*(lib: LibraryDb): seq[UserPlaylist] = @[]
  proc createPlaylist*(lib: LibraryDb, name: string): int64 = 0
  proc addTrackToPlaylist*(lib: LibraryDb, playlistId, trackId: int64, position: int) = discard
  proc removeTrackFromPlaylist*(lib: LibraryDb, playlistId, trackId: int64) = discard
  proc deletePlaylist*(lib: LibraryDb, playlistId: int64) = discard
  proc getPlaybackState*(lib: LibraryDb, key: string): string = ""
  proc setPlaybackState*(lib: LibraryDb, key, value: string) = discard
  proc updatePlayCount*(lib: LibraryDb, trackId: int64) = discard
  proc closeDb*(lib: LibraryDb) = discard
  proc getArtistId*(lib: LibraryDb, name: string): int64 = 0
  proc getAlbumId*(lib: LibraryDb, title: string, artistId: int64, year: int, genre: string): int64 = 0

proc displayName*(track: Track): string =
  if track.title.len > 0: track.title
  else: track.path.splitPath().tail

proc displayArtist*(track: Track): string =
  if track.artist.len > 0: track.artist else: "Unknown Artist"

proc displayAlbum*(track: Track): string =
  if track.album.len > 0: track.album else: "Unknown Album"

const audioExtensions* = [
  ".mp3", ".flac", ".ogg", ".m4a", ".wav", ".opus",
  ".aac", ".wma", ".alac", ".aiff", ".ape"
]

proc isAudioFile*(path: string): bool =
  let ext = path.splitFile().ext.toLowerAscii()
  ext in audioExtensions

proc scanDirectory*(dir: string): seq[string] =
  result = @[]
  if not dirExists(dir): return
  for kind, path in walkDir(dir):
    if kind == pcFile and isAudioFile(path):
      result.add(path)

proc scanDirectoryRecursive*(dir: string): seq[string] =
  result = @[]
  if not dirExists(dir): return
  for kind, path in walkDir(dir):
    if kind == pcFile and isAudioFile(path):
      result.add(path)
    elif kind == pcDir:
      result.add(scanDirectoryRecursive(path))

proc isUrl*(path: string): bool =
  path.startsWith("http://") or path.startsWith("https://") or
  path.startsWith("rtmp://") or path.startsWith("rtsp://") or
  path.startsWith("mms://") or path.startsWith("icy://") or
  path.startsWith("tcp://") or path.startsWith("udp://") or
  path.startsWith("ftp://")

const m3uExtensions = [".m3u", ".m3u8"]

proc isM3uFile*(path: string): bool =
  let ext = path.splitFile().ext.toLowerAscii()
  ext in m3uExtensions

proc parseM3u*(path: string): seq[string] =
  result = @[]
  if not fileExists(path): return
  let baseDir = path.parentDir()
  try:
    for line in lines(path):
      let trimmed = line.strip()
      if trimmed.len == 0 or trimmed.startsWith("#"): continue
      let fullPath = if trimmed.startsWith("/"): trimmed else: baseDir / trimmed
      if fileExists(fullPath): result.add(fullPath)
  except: discard

proc loadFromArgs*(args: seq[string]): seq[string] =
  result = @[]
  for arg in args:
    if isUrl(arg):
      result.add(arg)
    elif isM3uFile(arg):
      result.add(parseM3u(arg))
    elif dirExists(arg):
      result.add(scanDirectoryRecursive(arg))
    elif fileExists(arg):
      result.add(arg)
    else:
      try:
        for p in walkFiles(arg):
          if isAudioFile(p):
            result.add(p)
      except:
        discard

proc rebuildDisplayItems*(state: var AppState) =
  state.displayItems = @[]
  case state.tab
  of tabNowPlaying:
    for i, track in state.libraryTracks:
      state.displayItems.add(LibraryItem(
        kind: likTrack, trackIdx: i,
        label: track.displayName(),
        sublabel: track.displayArtist() & " - " & track.displayAlbum(),
        id: track.id
      ))
  of tabLibrary:
    if state.filterScope == fsArtists:
      for a in state.libraryArtists:
        state.displayItems.add(LibraryItem(kind: likArtist, label: a.name, sublabel: "", id: a.id))
    elif state.filterScope == fsAlbums:
      for a in state.libraryAlbums:
        state.displayItems.add(LibraryItem(
          kind: likAlbum, label: a.title,
          sublabel: a.artistName & " (" & $a.year & ")",
          id: a.id
        ))
    else:
      for i, track in state.libraryTracks:
        state.displayItems.add(LibraryItem(
          kind: likTrack, trackIdx: i,
          label: track.displayName(),
          sublabel: track.displayArtist() & " - " & track.displayAlbum(),
          id: track.id
        ))
  of tabPlaylists:
    for pl in state.libraryPlaylists:
      state.displayItems.add(LibraryItem(
        kind: likPlaylist, label: pl.name,
        sublabel: $pl.trackIds.len & " tracks",
        id: pl.id
      ))
  of tabSettings:
    state.displayItems.add(LibraryItem(kind: likTrack, label: "Theme: " & themeName(state.config.theme), sublabel: "Enter to change", id: 0))
    state.displayItems.add(LibraryItem(kind: likTrack, label: "Volume: " & $state.volume & "%", sublabel: "Shift+J/K or +/-", id: 1))
    state.displayItems.add(LibraryItem(kind: likTrack, label: "Refresh Theme: " & (if state.config.refreshTheme: "On" else: "Off"), sublabel: "Enter to toggle", id: 2))
    state.displayItems.add(LibraryItem(kind: likTrack, label: "Visualizer: " & (if state.vizVisible: "Visible" else: "Hidden"), sublabel: "Enter to toggle", id: 3))
    state.displayItems.add(LibraryItem(kind: likTrack, label: "Daemon: " & (if state.daemonConnected: "Connected" else: "Disconnected"), sublabel: "", id: 4))
