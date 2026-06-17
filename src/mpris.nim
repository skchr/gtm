import dbus, hashes

const
  DBUS_NAME_FLAG_DO_NOT_QUEUE* = 4.cuint
  DBUS_MESSAGE_TYPE_METHOD_CALL = 1

type
  MprisCtx* = object
    bus: Bus
    initialized: bool
    trackCounter: int64

var gMprisCtx*: MprisCtx

proc mprisPlaybackStatus(d: Daemon): string =
  case d.player.state
  of 1: "Playing"
  of 2: "Paused"
  else: "Stopped"

proc mprisLoopStatus(d: Daemon): string =
  case d.repeatMode
  of 1: "Playlist"
  of 2: "Track"
  else: "None"

proc mprisCanGoNext(d: Daemon): bool =
  if d.playbackQueue.len > 0: return true
  if d.shuffleEnabled and d.shuffleIndex < d.shuffleOrder.len: return true
  false

proc mprisCanGoPrevious(d: Daemon): bool =
  d.trackHistory.len > 0

proc mprisTrackId(d: Daemon): string =
  let h = hash(d.currentTrackPath)
  "/org/mpris/MediaPlayer2/gtmd/Track/" & h.toHex

proc mprisBuildMetadataArray(d: Daemon): DbusValue =
  result = DbusValue(kind: dtArray, arrayValueType: initDictEntryType(dtString, dtVariant))
  let trackId = mprisTrackId(d)
  result.add("mpris:trackid".asDbusValue, newVariant(trackId.ObjectPath.asDbusValue).asDbusValue)
  let lengthUs = int64(d.player.duration * 1_000_000)
  if lengthUs > 0:
    result.add("mpris:length".asDbusValue, newVariant(lengthUs.int64.asDbusValue).asDbusValue)
  var title = d.currentTrackTitle
  if title.len == 0 and d.currentTrackPath.len > 0:
    title = splitFile(d.currentTrackPath).name.replace(".", " ")
  if title.len > 0:
    result.add("xesam:title".asDbusValue, newVariant(title.asDbusValue).asDbusValue)
  var artist = d.currentTrackChannel
  if artist.len == 0: artist = d.player.metadata.artist
  if artist.len > 0:
    result.add("xesam:artist".asDbusValue, newVariant(@[artist].asDbusValue).asDbusValue)
  var album = d.player.metadata.album
  if album.len > 0:
    result.add("xesam:album".asDbusValue, newVariant(album.asDbusValue).asDbusValue)
  if d.currentTrackPath.len > 0:
    result.add("xesam:url".asDbusValue, newVariant(d.currentTrackPath.asDbusValue).asDbusValue)

proc mprisBuildAllProps(iface: string, d: Daemon): DbusValue =
  result = DbusValue(kind: dtArray, arrayValueType: initDictEntryType(dtString, dtVariant))
  if iface == "org.mpris.MediaPlayer2":
    result.add("Identity".asDbusValue, newVariant("gtmd".asDbusValue).asDbusValue)
    result.add("DesktopEntry".asDbusValue, newVariant("gtm".asDbusValue).asDbusValue)
    result.add("CanQuit".asDbusValue, newVariant(true.asDbusValue).asDbusValue)
    result.add("CanRaise".asDbusValue, newVariant(false.asDbusValue).asDbusValue)
    result.add("HasTrackList".asDbusValue, newVariant(true.asDbusValue).asDbusValue)
    result.add("SupportedUriSchemes".asDbusValue, newVariant(@["file", "http", "https"].asDbusValue).asDbusValue)
    result.add("SupportedMimeTypes".asDbusValue, newVariant(@["audio/flac", "audio/mpeg", "audio/mp4", "audio/ogg", "audio/wav", "audio/x-wav", "audio/x-flac", "audio/x-m4a", "audio/x-aiff"].asDbusValue).asDbusValue)
  elif iface == "org.mpris.MediaPlayer2.Player":
    result.add("PlaybackStatus".asDbusValue, newVariant(mprisPlaybackStatus(d).asDbusValue).asDbusValue)
    result.add("LoopStatus".asDbusValue, newVariant(mprisLoopStatus(d).asDbusValue).asDbusValue)
    result.add("Rate".asDbusValue, newVariant(1.0.float64.asDbusValue).asDbusValue)
    result.add("Shuffle".asDbusValue, newVariant(d.shuffleEnabled.asDbusValue).asDbusValue)
    result.add("Metadata".asDbusValue, newVariant(mprisBuildMetadataArray(d)).asDbusValue)
    result.add("Volume".asDbusValue, newVariant((d.player.volume.float64 / 100.0).asDbusValue).asDbusValue)
    result.add("Position".asDbusValue, newVariant(int64(d.player.timePos * 1_000_000).asDbusValue).asDbusValue)
    result.add("MinimumRate".asDbusValue, newVariant(1.0.float64.asDbusValue).asDbusValue)
    result.add("MaximumRate".asDbusValue, newVariant(1.0.float64.asDbusValue).asDbusValue)
    result.add("CanGoNext".asDbusValue, newVariant(mprisCanGoNext(d).asDbusValue).asDbusValue)
    result.add("CanGoPrevious".asDbusValue, newVariant(mprisCanGoPrevious(d).asDbusValue).asDbusValue)
    result.add("CanPlay".asDbusValue, newVariant(d.player.working.asDbusValue).asDbusValue)
    result.add("CanPause".asDbusValue, newVariant(d.player.working.asDbusValue).asDbusValue)
    result.add("CanSeek".asDbusValue, newVariant(d.player.working.asDbusValue).asDbusValue)
    result.add("CanControl".asDbusValue, newVariant(d.player.working.asDbusValue).asDbusValue)
  elif iface == "org.mpris.MediaPlayer2.TrackList":
    result.add("Tracks".asDbusValue, newVariant(newSeq[string]().asDbusValue).asDbusValue)
    result.add("CanEditTracks".asDbusValue, newVariant(false.asDbusValue).asDbusValue)

proc mprisGetSingleProp(iface, prop: string, d: Daemon): DbusValue =
  if iface == "org.mpris.MediaPlayer2":
    case prop
    of "Identity": return newVariant("gtmd".asDbusValue).asDbusValue
    of "DesktopEntry": return newVariant("gtm".asDbusValue).asDbusValue
    of "CanQuit": return newVariant(true.asDbusValue).asDbusValue
    of "CanRaise": return newVariant(false.asDbusValue).asDbusValue
    of "HasTrackList": return newVariant(true.asDbusValue).asDbusValue
    of "SupportedUriSchemes": return newVariant(@["file", "http", "https"].asDbusValue).asDbusValue
    of "SupportedMimeTypes": return newVariant(@["audio/flac", "audio/mpeg", "audio/mp4", "audio/ogg", "audio/wav"].asDbusValue).asDbusValue
    else: discard
  elif iface == "org.mpris.MediaPlayer2.Player":
    case prop
    of "PlaybackStatus": return newVariant(mprisPlaybackStatus(d).asDbusValue).asDbusValue
    of "LoopStatus": return newVariant(mprisLoopStatus(d).asDbusValue).asDbusValue
    of "Rate": return newVariant(1.0.float64.asDbusValue).asDbusValue
    of "Shuffle": return newVariant(d.shuffleEnabled.asDbusValue).asDbusValue
    of "Metadata": return newVariant(mprisBuildMetadataArray(d)).asDbusValue
    of "Volume": return newVariant((d.player.volume.float64 / 100.0).asDbusValue).asDbusValue
    of "Position": return newVariant(int64(d.player.timePos * 1_000_000).asDbusValue).asDbusValue
    of "MinimumRate": return newVariant(1.0.float64.asDbusValue).asDbusValue
    of "MaximumRate": return newVariant(1.0.float64.asDbusValue).asDbusValue
    of "CanGoNext": return newVariant(mprisCanGoNext(d).asDbusValue).asDbusValue
    of "CanGoPrevious": return newVariant(mprisCanGoPrevious(d).asDbusValue).asDbusValue
    of "CanPlay": return newVariant(d.player.working.asDbusValue).asDbusValue
    of "CanPause": return newVariant(d.player.working.asDbusValue).asDbusValue
    of "CanSeek": return newVariant(d.player.working.asDbusValue).asDbusValue
    of "CanControl": return newVariant(d.player.working.asDbusValue).asDbusValue
    else: discard
  elif iface == "org.mpris.MediaPlayer2.TrackList":
    case prop
    of "Tracks": return newVariant(newSeq[string]().asDbusValue).asDbusValue
    of "CanEditTracks": return newVariant(false.asDbusValue).asDbusValue
    else: discard

proc mprisSendReply(conn: ptr DBusConnection, msg: ptr DBusMessage, args: openarray[DbusValue]) =
  let reply = dbus_message_new_method_return(msg)
  if reply == nil: return
  var iter: DbusMessageIter
  dbus_message_iter_init_append(reply, addr iter)
  for a in args:
    (addr iter).append(a)
  discard dbus_connection_send(conn, reply, nil)
  dbus_message_unref(reply)

proc mprisSendEmptyReply(conn: ptr DBusConnection, msg: ptr DBusMessage) =
  let reply = dbus_message_new_method_return(msg)
  if reply == nil: return
  discard dbus_connection_send(conn, reply, nil)
  dbus_message_unref(reply)

proc mprisSendError(conn: ptr DBusConnection, msg: ptr DBusMessage, errName, errMsg: string) =
  let reply = dbus_message_new_error(msg, errName.cstring, errMsg.cstring)
  if reply == nil: return
  discard dbus_connection_send(conn, reply, nil)
  dbus_message_unref(reply)

proc mprisReadStringArg(iter: var DBusMessageIter): (bool, string) =
  if dbus_message_iter_get_arg_type(addr iter) != cint(dtString):
    return (false, "")
  var val: cstring
  dbus_message_iter_get_basic(addr iter, addr val)
  result = (true, $val)

proc mprisHandleIntrospect(conn: ptr DBusConnection, msg: ptr DBusMessage) =
  const xml = """
<!DOCTYPE node PUBLIC '-//freedesktop//DTD D-BUS Object Introspection 1.0//EN'
 'http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd'>
<node name='/org/mpris/MediaPlayer2'>
  <interface name='org.mpris.MediaPlayer2'>
    <method name='Raise'/><method name='Quit'/>
    <property name='CanQuit' type='b' access='read'/>
    <property name='CanRaise' type='b' access='read'/>
    <property name='HasTrackList' type='b' access='read'/>
    <property name='Identity' type='s' access='read'/>
    <property name='DesktopEntry' type='s' access='read'/>
    <property name='SupportedUriSchemes' type='as' access='read'/>
    <property name='SupportedMimeTypes' type='as' access='read'/>
  </interface>
  <interface name='org.mpris.MediaPlayer2.Player'>
    <method name='Next'/><method name='Previous'/>
    <method name='Pause'/><method name='PlayPause'/>
    <method name='Stop'/><method name='Play'/>
    <method name='Seek'><arg name='Offset' type='x' direction='in'/></method>
    <method name='SetPosition'><arg name='TrackId' type='o' direction='in'/><arg name='Position' type='x' direction='in'/></method>
    <method name='OpenUri'><arg name='Uri' type='s' direction='in'/></method>
    <signal name='Seeked'><arg name='Position' type='x'/></signal>
    <property name='PlaybackStatus' type='s' access='read'/>
    <property name='LoopStatus' type='s' access='readwrite'/>
    <property name='Rate' type='d' access='readwrite'/>
    <property name='Shuffle' type='b' access='readwrite'/>
    <property name='Metadata' type='a{sv}' access='read'/>
    <property name='Volume' type='d' access='readwrite'/>
    <property name='Position' type='x' access='read'/>
    <property name='MinimumRate' type='d' access='read'/>
    <property name='MaximumRate' type='d' access='read'/>
    <property name='CanGoNext' type='b' access='read'/>
    <property name='CanGoPrevious' type='b' access='read'/>
    <property name='CanPlay' type='b' access='read'/>
    <property name='CanPause' type='b' access='read'/>
    <property name='CanSeek' type='b' access='read'/>
    <property name='CanControl' type='b' access='read'/>
  </interface>
  <interface name='org.mpris.MediaPlayer2.TrackList'>
    <method name='GetTracksMetadata'><arg name='TrackIds' type='ao' direction='in'/><arg name='Metadata' type='aa{sv}' direction='out'/></method>
    <method name='AddTrack'><arg name='Uri' type='s' direction='in'/><arg name='AfterTrack' type='o' direction='in'/><arg name='SetAsCurrent' type='b' direction='in'/></method>
    <method name='RemoveTrack'><arg name='TrackId' type='o' direction='in'/></method>
    <method name='GoTo'><arg name='TrackId' type='o' direction='in'/></method>
    <property name='Tracks' type='ao' access='read'/>
    <property name='CanEditTracks' type='b' access='read'/>
  </interface>
  <interface name='org.freedesktop.DBus.Introspectable'>
    <method name='Introspect'><arg name='data' type='s' direction='out'/></method>
  </interface>
  <interface name='org.freedesktop.DBus.Properties'>
    <method name='Get'><arg name='interface_name' type='s' direction='in'/><arg name='property_name' type='s' direction='in'/><arg name='value' type='v' direction='out'/></method>
    <method name='Set'><arg name='interface_name' type='s' direction='in'/><arg name='property_name' type='s' direction='in'/><arg name='value' type='v' direction='in'/></method>
    <method name='GetAll'><arg name='interface_name' type='s' direction='in'/><arg name='properties' type='a{sv}' direction='out'/></method>
    <signal name='PropertiesChanged'><arg name='interface_name' type='s'/><arg name='changed_properties' type='a{sv}'/><arg name='invalidated_properties' type='as'/></signal>
  </interface>
</node>"""
  mprisSendReply(conn, msg, [xml.asDbusValue])

proc mprisHandlePropertyGet(conn: ptr DBusConnection, msg: ptr DBusMessage, d: Daemon) =
  var iter: DBusMessageIter
  if dbus_message_iter_init(msg, addr iter) == 0: return
  let (ok1, iface) = mprisReadStringArg(iter)
  if not ok1: return
  if dbus_message_iter_next(addr iter) == 0: return
  let (ok2, prop) = mprisReadStringArg(iter)
  if not ok2: return
  let val = mprisGetSingleProp(iface, prop, d)
  if val.isNil:
    mprisSendError(conn, msg, "org.freedesktop.DBus.Error.InvalidArgs", "no such property")
    return
  mprisSendReply(conn, msg, [val])

proc mprisHandlePropertyGetAll(conn: ptr DBusConnection, msg: ptr DBusMessage, d: Daemon) =
  var iter: DBusMessageIter
  if dbus_message_iter_init(msg, addr iter) == 0: return
  let (ok, iface) = mprisReadStringArg(iter)
  if not ok: return
  let props = mprisBuildAllProps(iface, d)
  if props.arrayValue.len == 0:
    mprisSendReply(conn, msg, [DbusValue(kind: dtArray, arrayValueType: initDictEntryType(dtString, dtVariant))])
    return
  mprisSendReply(conn, msg, [props])

proc mprisHandlePropertySet(conn: ptr DBusConnection, msg: ptr DBusMessage, d: Daemon) =
  var iter: DBusMessageIter
  if dbus_message_iter_init(msg, addr iter) == 0: return
  let (ok1, iface) = mprisReadStringArg(iter)
  if not ok1: return
  if dbus_message_iter_next(addr iter) == 0: return
  let (ok2, prop) = mprisReadStringArg(iter)
  if not ok2: return
  if dbus_message_iter_next(addr iter) == 0: return
  if dbus_message_iter_get_arg_type(addr iter) != cint(dtVariant): return
  var varIter: DBusMessageIter
  dbus_message_iter_recurse(addr iter, addr varIter)
  if iface == "org.mpris.MediaPlayer2.Player":
    case prop
    of "LoopStatus":
      let (ok3, val) = mprisReadStringArg(varIter)
      if ok3:
        case val
        of "None": d.repeatMode = 0
        of "Playlist": d.repeatMode = 1
        of "Track": d.repeatMode = 2
        else: discard
    of "Shuffle":
      if dbus_message_iter_get_arg_type(addr varIter) == cint(dtBool):
        var bval: dbus_bool_t
        dbus_message_iter_get_basic(addr varIter, addr bval)
        d.shuffleEnabled = bval != 0
        if d.shuffleEnabled and d.playbackQueue.len > 0:
          d.shuffleOrder = shuffleOrder(d.playbackQueue.len)
          d.shuffleIndex = 0
    of "Volume":
      if dbus_message_iter_get_arg_type(addr varIter) == cint(dtDouble):
        var dval: cdouble
        dbus_message_iter_get_basic(addr varIter, addr dval)
        d.player.setVolume(max(0, min(100, int(dval * 100.0))))
    else: discard
  mprisSendEmptyReply(conn, msg)

proc mprisHandlePlayerMethod(conn: ptr DBusConnection, msg: ptr DBusMessage, d: Daemon, methodName: string) =
  case methodName
  of "Play":
    if d.currentTrackPath.len > 0: d.player.play(); d.idleFrames = 0
  of "Pause":
    d.player.pause()
  of "PlayPause":
    d.player.togglePause()
  of "Stop":
    d.player.stop(); d.idleFrames = 0
  of "Next":
    discard d.advanceToNextTrack(true)
    d.sendQueueEvent()
  of "Previous":
    if d.trackHistory.len > 0:
      let prevPath = d.trackHistory.pop()
      d.pushTrackHistory(prevPath)
      if d.crossfadeDuration > 0 and d.player.state == 1:
        d.player.prepareNext(prevPath)
        d.player.startCrossfade(float(d.crossfadeDuration))
        d.currentTrackPath = prevPath
      else:
        d.player.stop(); discard d.player.loadFile(prevPath); d.currentTrackPath = prevPath; d.player.play()
      d.idleFrames = 0
    else: d.player.stop(); d.idleFrames = 0
    d.sendQueueEvent()
  of "Seek":
    var iter: DBusMessageIter
    if dbus_message_iter_init(msg, addr iter) == 0:
      mprisSendEmptyReply(conn, msg); return
    if dbus_message_iter_get_arg_type(addr iter) == cint(dtInt64):
      var offset: int64
      dbus_message_iter_get_basic(addr iter, addr offset)
      d.player.seek(d.player.timePos + (offset.float / 1_000_000.0))
  of "SetPosition":
    var iter: DBusMessageIter
    if dbus_message_iter_init(msg, addr iter) == 0:
      mprisSendEmptyReply(conn, msg); return
    if dbus_message_iter_get_arg_type(addr iter) == cint(dtObjectPath):
      if dbus_message_iter_next(addr iter) != 0 and dbus_message_iter_get_arg_type(addr iter) == cint(dtInt64):
        var pos: int64
        dbus_message_iter_get_basic(addr iter, addr pos)
        d.player.seek(pos.float / 1_000_000.0)
  of "OpenUri":
    var iter: DBusMessageIter
    if dbus_message_iter_init(msg, addr iter) == 0:
      mprisSendEmptyReply(conn, msg); return
    let (ok, uri) = mprisReadStringArg(iter)
    if ok and uri.len > 0:
      var path = uri
      if path.startsWith("file://"): path = path[7..^1]
      if path.len > 0:
        if d.currentTrackPath.len > 0 and d.currentTrackPath != path:
          d.trackHistory.add(d.currentTrackPath)
          if d.trackHistory.len > 50: d.trackHistory.delete(0)
        d.player.stop(); discard d.player.loadFile(path)
        d.currentTrackPath = path; d.currentTrackTitle = ""; d.currentTrackChannel = ""
        d.player.play(); d.idleFrames = 0
        if d.lib != nil:
          var trackId = d.lib.findTrackByPath(d.currentTrackPath)
          if trackId > 0: d.lib.updatePlayCount(trackId)
  else: discard
  mprisSendEmptyReply(conn, msg)

proc mprisHandleTrackListMethod(conn: ptr DBusConnection, msg: ptr DBusMessage, d: Daemon, methodName: string) =
  case methodName
  of "GetTracksMetadata":
    mprisSendReply(conn, msg, [DbusValue(kind: dtArray, arrayValueType: initDictEntryType(dtString, dtVariant))])
  of "AddTrack", "RemoveTrack", "GoTo":
    mprisSendEmptyReply(conn, msg)
  else: discard

proc mprisMessageFunc(connection: ptr DBusConnection, message: ptr DBusMessage, userData: pointer): DBusHandlerResult {.cdecl.} =
  let d = cast[Daemon](userData)
  if not gMprisCtx.initialized or gMprisCtx.bus.isNil:
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED
  if dbus_message_get_type(message) != DBUS_MESSAGE_TYPE_METHOD_CALL:
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED
  let iface = $dbus_message_get_interface(message)
  let member = $dbus_message_get_member(message)
  case iface
  of "org.freedesktop.DBus.Introspectable":
    if member == "Introspect": mprisHandleIntrospect(connection, message)
    return DBUS_HANDLER_RESULT_HANDLED
  of "org.freedesktop.DBus.Properties":
    case member
    of "Get": mprisHandlePropertyGet(connection, message, d)
    of "GetAll": mprisHandlePropertyGetAll(connection, message, d)
    of "Set": mprisHandlePropertySet(connection, message, d)
    else: return DBUS_HANDLER_RESULT_NOT_YET_HANDLED
    return DBUS_HANDLER_RESULT_HANDLED
  of "org.mpris.MediaPlayer2":
    case member
    of "Raise": discard
    of "Quit": d.running = false
    else: return DBUS_HANDLER_RESULT_NOT_YET_HANDLED
    mprisSendEmptyReply(connection, message)
    return DBUS_HANDLER_RESULT_HANDLED
  of "org.mpris.MediaPlayer2.Player":
    mprisHandlePlayerMethod(connection, message, d, member)
    return DBUS_HANDLER_RESULT_HANDLED
  of "org.mpris.MediaPlayer2.TrackList":
    mprisHandleTrackListMethod(connection, message, d, member)
    return DBUS_HANDLER_RESULT_HANDLED
  else: discard
  DBUS_HANDLER_RESULT_NOT_YET_HANDLED

proc mprisUnregisterFunc(connection: ptr DBusConnection, userData: pointer) {.cdecl.} = discard

proc initMpris*(d: Daemon) =
  discard dbus_threads_init_default()
  var err: DBusError
  dbus_error_init(addr err)
  let conn = dbus_bus_get(DBUS_BUS_SESSION, addr err)
  if conn == nil:
    echo "[gtm] MPRIS: could not connect to session bus: " & $err.message
    dbus_error_free(addr err)
    return
  gMprisCtx.bus = Bus(conn: conn)
  let ret = dbus_bus_request_name(conn, "org.mpris.MediaPlayer2.gtmd".cstring,
                                   DBUS_NAME_FLAG_DO_NOT_QUEUE, addr err)
  if ret < 0:
    echo "[gtm] MPRIS: could not request name: " & $err.message
    dbus_error_free(addr err)
    return
  var vtable: DBusObjectPathVTable
  reset(vtable)
  vtable.message_function = mprisMessageFunc
  vtable.unregister_function = mprisUnregisterFunc
  dbus_error_init(addr err)
  let ok = dbus_connection_try_register_object_path(conn, "/org/mpris/MediaPlayer2".cstring,
                                                      addr vtable, cast[pointer](d), addr err)
  if ok == 0:
    echo "[gtm] MPRIS: could not register object path: " & $err.message
    dbus_error_free(addr err)
    return
  gMprisCtx.initialized = true
  echo "[gtm] MPRIS: registered as org.mpris.MediaPlayer2.gtmd"

proc pollMpris*() =
  if not gMprisCtx.initialized or gMprisCtx.bus.isNil: return
  discard dbus_connection_read_write_dispatch(gMprisCtx.bus.conn, 0)

proc emitMprisPlayerChanged*(d: Daemon) =
  if not gMprisCtx.initialized or gMprisCtx.bus.isNil: return
  var sig = makeSignal("/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties", "PropertiesChanged")
  sig.append("org.mpris.MediaPlayer2.Player".asDbusValue)
  sig.append(mprisBuildAllProps("org.mpris.MediaPlayer2.Player", d))
  sig.append(newSeq[string]().asDbusValue)
  discard gMprisCtx.bus.sendMessage(sig)

proc emitMprisSeeked*(positionUs: int64) =
  if not gMprisCtx.initialized or gMprisCtx.bus.isNil: return
  var sig = makeSignal("/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", "Seeked")
  sig.append(positionUs.asDbusValue)
  discard gMprisCtx.bus.sendMessage(sig)

proc shutdownMpris*() =
  if not gMprisCtx.initialized or gMprisCtx.bus.isNil: return
  gMprisCtx.bus.flush()
  gMprisCtx.initialized = false
