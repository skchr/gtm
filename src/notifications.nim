import dbus

var gNotifyConn: ptr DBusConnection = nil

proc initNotifications*() =
  if gNotifyConn != nil: return
  discard dbus_threads_init_default()
  var err: DBusError
  dbus_error_init(addr err)
  let conn = dbus_bus_get(DBUS_BUS_SESSION, addr err)
  if conn == nil:
    echo "[gtm] Notifications: could not connect to session bus: " & $err.message
    dbus_error_free(addr err)
    return
  gNotifyConn = conn

proc sendDesktopNotification*(title, body: string) =
  if gNotifyConn == nil: return
  var msg = makeCall("org.freedesktop.Notifications",
    ObjectPath("/org/freedesktop/Notifications"),
    "org.freedesktop.Notifications", "Notify")
  msg.append("gtm".asDbusValue)
  msg.append(0.uint32.asDbusValue)
  msg.append("".asDbusValue)
  msg.append(title.asDbusValue)
  msg.append(body.asDbusValue)
  msg.append(newSeq[string]().asDbusValue)
  var hints = DbusValue(kind: dtArray, arrayValueType: initDictEntryType(dtString, dtVariant))
  var entry = DbusValue(kind: dtDictEntry,
    dictKey: "desktop-entry".asDbusValue,
    dictValue: DbusValue(kind: dtVariant, variantType: dtString, variantValue: "gtm".asDbusValue))
  hints.arrayValue.add(entry)
  msg.append(hints)
  msg.append((-1).int32.asDbusValue)
  let bus = Bus(conn: gNotifyConn)
  discard bus.sendMessage(msg)
  discard dbus_connection_read_write_dispatch(gNotifyConn, 0)

proc shutdownNotifications*() =
  if gNotifyConn == nil: return
  dbus_connection_flush(gNotifyConn)
  dbus_connection_close(gNotifyConn)
  gNotifyConn = nil
