## Store — central state management for the TUI
##
## Store owns AppState + DaemonService and provides a subscription/dispatch
## pattern for widget notifications. All daemon IPC flows through
## store.service; no code outside daemonservice.nim imports client.nim.
##
## ┌─────────────────────────────────────────────────────┐
## │  Store (ref object)                                 │
## │                                                     │
## │  ┌─────────────────┐  ┌─────────────────────────┐  │
## │  │  app: AppState   │  │  service: DaemonService │  │
## │  │  (pure data)     │  │  (typed IPC proxy)      │  │
## │  └─────────────────┘  │  .client = .app.player   │  │
## │                        └─────────────────────────┘  │
## │                                                     │
## │  subscribe(widgetId, {ceTrack, cePlayState, ...})   │
## │  dispatch(ceTrack) — marks dirty + notifies subs    │
## └─────────────────────────────────────────────────────┘
##
## Widgets receive Context[Store] and access AppState via
## ctx.state (template). Daemon IPC via ctx.data.service.

import state, daemonservice, audio

type
  Subscription* = object
    widgetId*: int
    events*: set[ChangeEvent]

  Store* = ref object
    app*: AppState
    service*: DaemonService
    subs*: seq[Subscription]
    nextWidgetId*: int

proc newStore*(): Store =
  let svc = newDaemonService()
  result = Store(
    app: AppState(overlayOpacity: 0.85),
    service: svc,
    subs: @[],
    nextWidgetId: 0
  )
  # service.session and app.player point to the same DaemonSession
  result.app.player = svc.session
  result.app.svc = svc

# ── Subscription API ────────────────────────────────────────

proc subscribe*(store: var Store, events: set[ChangeEvent]): int =
  result = store.nextWidgetId
  store.nextWidgetId.inc
  store.subs.add(Subscription(widgetId: result, events: events))

proc markDirty*(store: var Store, event: ChangeEvent) =
  store.app.markDirty(event)

proc markDirtyBatch*(store: var Store, events: varargs[ChangeEvent]) =
  for e in events: store.app.markDirty(e)

proc player*(store: Store): AudioBackend = store.app.player
