import os, strutils, sequtils, algorithm, sets, tables, times
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
      CREATE TABLE IF NOT EXISTS favourites (
        track_id INTEGER PRIMARY KEY REFERENCES tracks(id),
        added_at TEXT DEFAULT (datetime('now'))
      )
    """)
    discard execRaw(lib.db, """
      CREATE TABLE IF NOT EXISTS playback_state (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    """)
    discard execRaw(lib.db, """
      CREATE TABLE IF NOT EXISTS downloads (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_url TEXT UNIQUE NOT NULL,
        local_path TEXT NOT NULL,
        title TEXT DEFAULT '',
        channel TEXT DEFAULT '',
        downloaded_at TEXT DEFAULT (datetime('now'))
      )
    """)
    discard execRaw(lib.db, """
      CREATE TABLE IF NOT EXISTS search_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        query TEXT NOT NULL,
        searched_at TEXT DEFAULT (datetime('now'))
      )
    """)
    discard execRaw(lib.db, """
      CREATE TABLE IF NOT EXISTS trash (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        track_id INTEGER NOT NULL,
        original_path TEXT NOT NULL,
        trash_path TEXT NOT NULL,
        trashed_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL
      )
    """)

  proc addFavourite*(lib: LibraryDb, trackId: int64) =
    let stmt = prepare(lib.db, "INSERT OR IGNORE INTO favourites (track_id) VALUES (?)")
    if stmt == nil: return
    bindInt64(stmt, 1.cint, trackId)
    discard sqlite3_step(stmt)
    finalize(stmt)

  proc removeFavourite*(lib: LibraryDb, trackId: int64) =
    let stmt = prepare(lib.db, "DELETE FROM favourites WHERE track_id = ?")
    if stmt == nil: return
    bindInt64(stmt, 1.cint, trackId)
    discard sqlite3_step(stmt)
    finalize(stmt)

  proc getFavourites*(lib: LibraryDb): seq[int64] =
    let stmt = prepare(lib.db, "SELECT track_id FROM favourites ORDER BY added_at DESC")
    if stmt == nil: return
    while sqlite3_step(stmt) == SQLITE_ROW:
      result.add(colInt64(stmt, 0.cint))
    finalize(stmt)

  proc isFavourite*(lib: LibraryDb, trackId: int64): bool =
    let stmt = prepare(lib.db, "SELECT count(*) FROM favourites WHERE track_id = ?")
    if stmt == nil: return false
    bindInt64(stmt, 1.cint, trackId)
    if sqlite3_step(stmt) == SQLITE_ROW:
      result = colInt64(stmt, 0.cint) > 0
    finalize(stmt)

  proc getArtistId*(lib: LibraryDb, name: string): int64 =
    let adjusted = if name.len == 0: "Unknown Artist" else: name
    let stmt = prepare(lib.db, "SELECT id FROM artists WHERE name = ?")
    if stmt == nil: return 0
    bindText(stmt, 1.cint, adjusted)
    if sqlite3_step(stmt) == SQLITE_ROW:
      result = colInt64(stmt, 0.cint)
    else:
      finalize(stmt)
      let ins = prepare(lib.db, "INSERT INTO artists (name) VALUES (?)")
      if ins != nil:
        bindText(ins, 1.cint, adjusted)
        discard sqlite3_step(ins)
        finalize(ins)
      result = sqlite3_last_insert_rowid(lib.db)
      return
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
      SELECT t.id, t.path, t.title, a.name, al.title, t.duration, t.track_num, t.year, t.genre, t.play_count, t.artist_id, t.album_id, t.added_at, t.last_played
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
        artistId: colInt64(stmt, 10.cint), albumId: colInt64(stmt, 11.cint),
        addedAt: colText(stmt, 12.cint), lastPlayed: colText(stmt, 13.cint)
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
    let stmt = prepare(lib.db, "INSERT INTO playlists (name) VALUES (?)")
    if stmt == nil: return 0
    bindText(stmt, 1.cint, name)
    if sqlite3_step(stmt) != SQLITE_OK:
      finalize(stmt)
      return 0
    finalize(stmt)
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
    let stmt2 = prepare(lib.db, "DELETE FROM playlists WHERE id = ?")
    if stmt2 != nil:
      bindInt64(stmt2, 1.cint, playlistId)
      discard sqlite3_step(stmt2)
      finalize(stmt2)

  proc renamePlaylist*(lib: LibraryDb, playlistId: int64, name: string) =
    if name.len == 0: return
    let stmt = prepare(lib.db, "UPDATE playlists SET name = ? WHERE id = ?")
    if stmt == nil: return
    bindText(stmt, 1.cint, name)
    bindInt64(stmt, 2.cint, playlistId)
    discard sqlite3_step(stmt)
    finalize(stmt)

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

  proc findTrackByPath*(lib: LibraryDb, path: string): int64 =
    let stmt = prepare(lib.db, "SELECT id FROM tracks WHERE path = ?")
    if stmt == nil: return 0
    bindText(stmt, 1.cint, path)
    if sqlite3_step(stmt) == SQLITE_ROW:
      result = colInt64(stmt, 0.cint)
    finalize(stmt)

  proc updatePlayCount*(lib: LibraryDb, trackId: int64) =
    let stmt = prepare(lib.db, "UPDATE tracks SET play_count = play_count + 1, last_played = datetime('now') WHERE id = ?")
    if stmt == nil: return
    bindInt64(stmt, 1.cint, trackId)
    discard sqlite3_step(stmt)
    finalize(stmt)

  proc updateTrackPath*(lib: LibraryDb, oldPath, newPath, newTitle: string) =
    let stmt = prepare(lib.db, "UPDATE tracks SET path=?, title=? WHERE path=?")
    if stmt != nil:
      bindText(stmt, 1.cint, newPath)
      bindText(stmt, 2.cint, newTitle)
      bindText(stmt, 3.cint, oldPath)
      discard sqlite3_step(stmt)
      finalize(stmt)

  proc addDownload*(lib: LibraryDb, sourceUrl, localPath, title, channel: string) =
    let stmt = prepare(lib.db, "INSERT OR IGNORE INTO downloads (source_url, local_path, title, channel) VALUES (?, ?, ?, ?)")
    if stmt == nil: return
    bindText(stmt, 1.cint, sourceUrl)
    bindText(stmt, 2.cint, localPath)
    bindText(stmt, 3.cint, title)
    bindText(stmt, 4.cint, channel)
    discard sqlite3_step(stmt)
    finalize(stmt)

  proc getDownloadByUrl*(lib: LibraryDb, sourceUrl: string): string =
    let stmt = prepare(lib.db, "SELECT local_path FROM downloads WHERE source_url = ?")
    if stmt == nil: return ""
    bindText(stmt, 1.cint, sourceUrl)
    if sqlite3_step(stmt) == SQLITE_ROW:
      result = colText(stmt, 0.cint)
    finalize(stmt)

  proc getDownloadMetaByUrl*(lib: LibraryDb, sourceUrl: string): tuple[path, title, channel: string] =
    let stmt = prepare(lib.db, "SELECT local_path, title, channel FROM downloads WHERE source_url = ?")
    if stmt == nil: return ("", "", "")
    bindText(stmt, 1.cint, sourceUrl)
    if sqlite3_step(stmt) == SQLITE_ROW:
      result = (colText(stmt, 0.cint), colText(stmt, 1.cint), colText(stmt, 2.cint))
    finalize(stmt)

  proc getDownloads*(lib: LibraryDb): seq[tuple[url, path, title: string]] =
    let stmt = prepare(lib.db, "SELECT source_url, local_path, title FROM downloads ORDER BY downloaded_at DESC")
    if stmt == nil: return
    while sqlite3_step(stmt) == SQLITE_ROW:
      result.add((colText(stmt, 0.cint), colText(stmt, 1.cint), colText(stmt, 2.cint)))
    finalize(stmt)

  proc addSearchQuery*(lib: LibraryDb, query: string) =
    let stmt = prepare(lib.db, "INSERT INTO search_history (query) VALUES (?)")
    if stmt == nil: return
    bindText(stmt, 1.cint, query)
    discard sqlite3_step(stmt)
    finalize(stmt)

  proc getSearchHistory*(lib: LibraryDb): seq[string] =
    let stmt = prepare(lib.db, "SELECT DISTINCT query FROM search_history ORDER BY searched_at DESC LIMIT 50")
    if stmt == nil: return
    while sqlite3_step(stmt) == SQLITE_ROW:
      result.add(colText(stmt, 0.cint))
    finalize(stmt)

  proc clearSearchHistory*(lib: LibraryDb) =
    discard execRaw(lib.db, "DELETE FROM search_history")

  proc trashTrack*(lib: LibraryDb, trackId: int64, originalPath, trashPath: string) =
    let now = epochTime().int
    let stmt = prepare(lib.db, "INSERT INTO trash (track_id, original_path, trash_path, trashed_at, expires_at) VALUES (?, ?, ?, ?, ?)")
    if stmt == nil: return
    bindInt64(stmt, 1.cint, trackId)
    bindText(stmt, 2.cint, originalPath)
    bindText(stmt, 3.cint, trashPath)
    bindInt(stmt, 4.cint, now)
    bindInt(stmt, 5.cint, now + 604800)
    discard sqlite3_step(stmt)
    finalize(stmt)

  proc restoreTrack*(lib: LibraryDb, trashId: int): tuple[trackId: int64, originalPath, trashPath: string] =
    let stmt = prepare(lib.db, "SELECT track_id, original_path, trash_path FROM trash WHERE id = ?")
    if stmt == nil: return
    bindInt(stmt, 1.cint, trashId)
    if sqlite3_step(stmt) == SQLITE_ROW:
      result.trackId = colInt64(stmt, 0.cint)
      result.originalPath = colText(stmt, 1.cint)
      result.trashPath = colText(stmt, 2.cint)
    finalize(stmt)
    if result.originalPath.len > 0:
      let del = prepare(lib.db, "DELETE FROM trash WHERE id = ?")
      if del != nil:
        bindInt(del, 1.cint, trashId)
        discard sqlite3_step(del)
        finalize(del)

  proc permanentDeleteTrash*(lib: LibraryDb, trashId: int) =
    let stmt = prepare(lib.db, "DELETE FROM trash WHERE id = ?")
    if stmt == nil: return
    bindInt(stmt, 1.cint, trashId)
    discard sqlite3_step(stmt)
    finalize(stmt)

  proc listTrash*(lib: LibraryDb): seq[tuple[id: int, trackId: int64, originalPath, trashPath: string, trashedAt, expiresAt: int]] =
    let stmt = prepare(lib.db, "SELECT id, track_id, original_path, trash_path, trashed_at, expires_at FROM trash ORDER BY trashed_at DESC")
    if stmt == nil: return
    while sqlite3_step(stmt) == SQLITE_ROW:
      result.add((
        colInt(stmt, 0.cint),
        colInt64(stmt, 1.cint),
        colText(stmt, 2.cint),
        colText(stmt, 3.cint),
        colInt(stmt, 4.cint),
        colInt(stmt, 5.cint)
      ))
    finalize(stmt)

  proc purgeExpiredTrash*(lib: LibraryDb): seq[tuple[trashPath, originalPath: string]] =
    let now = epochTime().int
    let stmt = prepare(lib.db, "SELECT id, trash_path, original_path FROM trash WHERE expires_at <= ?")
    if stmt == nil: return
    bindInt(stmt, 1.cint, now)
    while sqlite3_step(stmt) == SQLITE_ROW:
      result.add((colText(stmt, 1.cint), colText(stmt, 2.cint)))
      let tid = colInt(stmt, 0.cint)
      let del = prepare(lib.db, "DELETE FROM trash WHERE id = ?")
      if del != nil:
        bindInt(del, 1.cint, tid)
        discard sqlite3_step(del)
        finalize(del)
    finalize(stmt)

  proc deleteTrack*(lib: LibraryDb, trackId: int64) =
    var stmt = prepare(lib.db, "DELETE FROM favourites WHERE track_id = ?")
    if stmt != nil:
      bindInt64(stmt, 1.cint, trackId)
      discard sqlite3_step(stmt)
      finalize(stmt)
    stmt = prepare(lib.db, "DELETE FROM playlist_tracks WHERE track_id = ?")
    if stmt != nil:
      bindInt64(stmt, 1.cint, trackId)
      discard sqlite3_step(stmt)
      finalize(stmt)
    stmt = prepare(lib.db, "DELETE FROM tracks WHERE id = ?")
    if stmt != nil:
      bindInt64(stmt, 1.cint, trackId)
      discard sqlite3_step(stmt)
      finalize(stmt)

  proc getTrackPath*(lib: LibraryDb, trackId: int64): string =
    let stmt = prepare(lib.db, "SELECT path FROM tracks WHERE id = ?")
    if stmt != nil:
      bindInt64(stmt, 1.cint, trackId)
      if sqlite3_step(stmt) == SQLITE_ROW:
        result = colText(stmt, 0.cint)
      finalize(stmt)

  proc getTrashPath*(lib: LibraryDb, trashId: int): string =
    let stmt = prepare(lib.db, "SELECT trash_path FROM trash WHERE id = ?")
    if stmt != nil:
      bindInt(stmt, 1.cint, trashId)
      if sqlite3_step(stmt) == SQLITE_ROW:
        result = colText(stmt, 0.cint)
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
  proc renamePlaylist*(lib: LibraryDb, playlistId: int64, name: string) = discard
  proc getPlaybackState*(lib: LibraryDb, key: string): string = ""
  proc setPlaybackState*(lib: LibraryDb, key, value: string) = discard
  proc findTrackByPath*(lib: LibraryDb, path: string): int64 = 0
  proc updatePlayCount*(lib: LibraryDb, trackId: int64) = discard
  proc updateTrackPath*(lib: LibraryDb, oldPath, newPath, newTitle: string) = discard
  proc closeDb*(lib: LibraryDb) = discard
  proc getArtistId*(lib: LibraryDb, name: string): int64 = 0
  proc getAlbumId*(lib: LibraryDb, title: string, artistId: int64, year: int, genre: string): int64 = 0
  proc addFavourite*(lib: LibraryDb, trackId: int64) = discard
  proc removeFavourite*(lib: LibraryDb, trackId: int64) = discard
  proc getFavourites*(lib: LibraryDb): seq[int64] = @[]
  proc isFavourite*(lib: LibraryDb, trackId: int64): bool = false
  proc addDownload*(lib: LibraryDb, sourceUrl, localPath, title, channel: string) = discard
  proc getDownloadByUrl*(lib: LibraryDb, sourceUrl: string): string = ""
  proc getDownloadMetaByUrl*(lib: LibraryDb, sourceUrl: string): tuple[path, title, channel: string] = ("", "", "")
  proc getDownloads*(lib: LibraryDb): seq[tuple[url, path, title: string]] = @[]
  proc addSearchQuery*(lib: LibraryDb, query: string) = discard
  proc getSearchHistory*(lib: LibraryDb): seq[string] = @[]
  proc clearSearchHistory*(lib: LibraryDb) = discard
  proc trashTrack*(lib: LibraryDb, trackId: int64, originalPath, trashPath: string) = discard
  proc restoreTrack*(lib: LibraryDb, trashId: int): tuple[trackId: int64, originalPath, trashPath: string] = (0, "", "")
  proc permanentDeleteTrash*(lib: LibraryDb, trashId: int) = discard
  proc listTrash*(lib: LibraryDb): seq[tuple[id: int, trackId: int64, originalPath, trashPath: string, trashedAt, expiresAt: int]] = @[]
  proc purgeExpiredTrash*(lib: LibraryDb): seq[tuple[trashPath, originalPath: string]] = @[]
  proc deleteTrack*(lib: LibraryDb, trackId: int64) = discard
  proc getTrackPath*(lib: LibraryDb, trackId: int64): string = ""
  proc getTrashPath*(lib: LibraryDb, trashId: int): string = ""

proc displayName*(track: Track): string =
  if track.title.len > 0: track.title
  else: track.path.splitPath().tail

proc displayArtist*(track: Track): string =
  if track.artist.len > 0: track.artist else: "Unknown Artist"

proc displayAlbum*(track: Track): string =
  if track.album.len > 0: track.album else: "Unknown Album"

proc parseFilenameMetadata*(path: string): tuple[title, artist, album: string] =
  let (_, name, _) = path.splitFile()
  var title = name
  var artist = ""
  var album = ""
  let dashPos = name.find(" - ")
  if dashPos > 0:
    let left = name[0..<dashPos].strip()
    let right = name[dashPos+3..^1].strip()
    var isTrackNum = left.len in {2, 3}
    if isTrackNum:
      for c in left:
        if c notin {'0'..'9'}: isTrackNum = false; break
    if isTrackNum:
      title = right
    else:
      artist = left
      title = right
  if title.len == 0:
    title = name
  result = (title, artist, album)

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

proc isYtWatchUrl*(path: string): bool =
  (path.contains("youtube.com/watch") or path.contains("youtu.be/")) and
  not path.contains("googlevideo.com")

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
  except: stderr.writeLine("[gtm] parseM3u error: " & getCurrentExceptionMsg())

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
        stderr.writeLine("[gtm] loadFromArgs error: " & getCurrentExceptionMsg())

proc addTrackItems(state: var AppState, indices: seq[int]) =
  for i in indices:
    if i >= 0 and i < state.libraryTracks.len:
      let track = state.libraryTracks[i]
      state.displayItems.add(LibraryItem(
        kind: likTrack, trackIdx: i,
        label: track.displayName(),
        sublabel: track.displayArtist() & " - " & track.displayAlbum(),
        id: track.id
      ))

proc sortedIndices(state: AppState, field: string): seq[int] =
  result = toSeq(0..<state.libraryTracks.len)
  case field
  of "addedAt":
    result.sort(proc(a, b: int): int = cmp(state.libraryTracks[b].addedAt, state.libraryTracks[a].addedAt))
  of "lastPlayed":
    result.sort(proc(a, b: int): int = cmp(state.libraryTracks[b].lastPlayed, state.libraryTracks[a].lastPlayed))
  of "mostPlayed":
    result.sort(proc(a, b: int): int = cmp(state.libraryTracks[b].playCount, state.libraryTracks[a].playCount))
  of "leastPlayed":
    result.sort(proc(a, b: int): int = cmp(state.libraryTracks[a].playCount, state.libraryTracks[b].playCount))
  else: discard

proc rebuildItems*(state: var AppState) =
  state.displayItems = @[]
  case state.tab
  of tabNowPlaying:
    state.addTrackItems(toSeq(0..<state.libraryTracks.len))
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
    elif state.filterScope == fsPlaylists:
      for pl in state.libraryPlaylists:
        state.displayItems.add(LibraryItem(
          kind: likPlaylist, label: pl.name,
          sublabel: $pl.trackIds.len & " tracks",
          id: pl.id
        ))
    elif state.filterScope == fsFavourites:
      var favIndices: seq[int] = @[]
      for i, t in state.libraryTracks:
        if t.id in state.favouriteIds or t.isFavourite:
          favIndices.add(i)
      state.addTrackItems(favIndices)
    elif state.filterScope == fsRecent:
      state.addTrackItems(state.sortedIndices("addedAt"))
    elif state.filterScope == fsLastPlayed:
      state.addTrackItems(state.sortedIndices("lastPlayed"))
    elif state.filterScope == fsMostPlayed:
      state.addTrackItems(state.sortedIndices("mostPlayed"))
    elif state.filterScope == fsLeastPlayed:
      state.addTrackItems(state.sortedIndices("leastPlayed"))
    elif state.filterScope == fsDownloads:
      var dlIndices: seq[int] = @[]
      let dlDir = state.ytDownloadDir
      for i, t in state.libraryTracks:
        if t.path.startsWith(dlDir):
          dlIndices.add(i)
        else:
          for k, v in state.ytDownloaded:
            if v == t.path:
              dlIndices.add(i)
              break
      state.addTrackItems(dlIndices)
    else:
      state.addTrackItems(toSeq(0..<state.libraryTracks.len))
  of tabSettings:
    state.displayItems.add(LibraryItem(kind: likTrack, label: "Theme: " & themeName(state.config.theme), sublabel: "Enter to change", id: 0))
    state.displayItems.add(LibraryItem(kind: likTrack, label: "Volume: " & $state.volume & "%", sublabel: "Shift+J/K or +/-", id: 1))
    state.displayItems.add(LibraryItem(kind: likTrack, label: "Refresh Theme: " & (if state.config.refreshTheme: "On" else: "Off"), sublabel: "Enter to toggle", id: 2))
    state.displayItems.add(LibraryItem(kind: likTrack, label: "Daemon: " & (if state.daemonConnected: "Connected" else: "Disconnected"), sublabel: "", id: 4))
    state.displayItems.add(LibraryItem(kind: likTrack, label: "Reset to Defaults", sublabel: "Enter to reset all settings", id: 5))
    state.displayItems.add(LibraryItem(kind: likTrack, label: "Max Concurrent Downloads: " & $state.ytMaxConcurrentDownloads, sublabel: "Enter to adjust", id: 7))
    state.displayItems.add(LibraryItem(kind: likTrack, label: "Batch YT Mode: " & (if state.ytBatchDownloadMode: "Download" else: "URL Ref"), sublabel: "Enter to toggle", id: 8))
    let cookieLabel = if state.ytCookieSource.len == 0: "(none)" else: state.ytCookieSource
    state.displayItems.add(LibraryItem(kind: likTrack, label: "YT Cookie: " & cookieLabel, sublabel: "Enter to change", id: 9))
    let runtimeLabel = if state.ytJsRuntime.len == 0: "node (default)" else: state.ytJsRuntime
    state.displayItems.add(LibraryItem(kind: likTrack, label: "YT JS Runtime: " & runtimeLabel, sublabel: "Enter to cycle", id: 10))
    state.displayItems.add(LibraryItem(kind: likTrack, label: "Clear Search History (" & $state.ytSearchHistory.len & " entries)", sublabel: "Enter to clear", id: 11))
    state.displayItems.add(LibraryItem(kind: likTrack, label: "Results Per Page: " & $state.ytSearchPageSize, sublabel: "Enter to adjust", id: 12))
    state.displayItems.add(LibraryItem(kind: likTrack, label: "Crossfade Duration: " & $state.crossfadeDuration & "s", sublabel: "Enter to adjust", id: 13))
  state.selectIndex = min(state.selectIndex, state.displayItems.len - 1)
  if state.selectIndex < 0 and state.displayItems.len > 0:
    state.selectIndex = 0
