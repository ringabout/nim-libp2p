## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[options, tables, sequtils, sets, sugar]
import chronos, chronicles, metrics
import peerinfo,
       stream/connection,
       muxers/muxer,
       utils/semaphore,
       errors
       utils/semaphore

logScope:
  topics = "connmanager"

declareGauge(libp2p_peers, "total connected peers")

const
  MaxConnections = 100

type
  TooManyConnections* = object of CatchableError

  ConnEventKind* {.pure.} = enum
    Connected,    # A connection was made and securely upgraded - there may be
                  # more than one concurrent connection thus more than one upgrade
                  # event per peer.

    Disconnected  # Peer disconnected - this event is fired once per upgrade
                  # when the associated connection is terminated.

  ConnEvent* = object
    case kind*: ConnEventKind
    of ConnEventKind.Connected:
      incoming*: bool
    else:
      discard

  ConnEventHandler* =
    proc(peerId: PeerID, event: ConnEvent): Future[void] {.gcsafe.}

  PeerEvent* {.pure.} = enum
    Left,
    Joined

  PeerEventHandler* =
    proc(peerId: PeerID, event: PeerEvent): Future[void] {.gcsafe.}

  MuxerHolder = object
    muxer: Muxer
    handle: Future[void]

  ConnManager* = ref object of RootObj
    maxConns: int
    connSemaphore*: AsyncSemaphore
    muxed: Table[Connection, MuxerHolder]
    # NOTE: don't change to PeerInfo here
    # the reference semantics on the PeerInfo
    # object itself make it susceptible to
    # copies and mangling by unrelated code.
    conns: seq[Connection]
    connEvents: Table[ConnEventKind, OrderedSet[ConnEventHandler]]
    peerEvents: Table[PeerEvent, OrderedSet[PeerEventHandler]]

proc init*(C: type ConnManager, maxConns: int = MaxConnections): ConnManager =
  C(maxConns: maxConns,
    muxed: initTable[Connection, MuxerHolder](),
    connSemaphore: AsyncSemaphore.init(maxConns))

proc connCount*(c: ConnManager, peerId: PeerID): int =
  c.conns
  .filter(
    proc(conn: Connection): bool =
      (not isNil(conn.peerInfo) and conn.peerInfo.peerId == peerId)
  ).len

proc connCount*(c: ConnManager, peerId: PeerID): int =
  c.conns.getOrDefault(peerId).len

proc addConnEventHandler*(c: ConnManager,
                          handler: ConnEventHandler, kind: ConnEventKind) =
  ## Add peer event handler - handlers must not raise exceptions!
  ##

  if isNil(handler): return
  c.connEvents.mgetOrPut(kind,
    initOrderedSet[ConnEventHandler]()).incl(handler)

proc removeConnEventHandler*(c: ConnManager,
                             handler: ConnEventHandler, kind: ConnEventKind) =
  c.connEvents.withValue(kind, handlers) do:
    handlers[].excl(handler)

proc triggerConnEvent*(c: ConnManager, peerId: PeerID, event: ConnEvent) {.async, gcsafe.} =
  try:
    if event.kind in c.connEvents:
      var connEvents: seq[Future[void]]
      for h in c.connEvents[event.kind]:
        connEvents.add(h(peerId, event))

      checkFutures(await allFinished(connEvents))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc: # handlers should not raise!
    warn "Exception in triggerConnEvents",
      msg = exc.msg, peerId, event = $event

proc addPeerEventHandler*(c: ConnManager,
                          handler: PeerEventHandler,
                          kind: PeerEvent) =
  ## Add peer event handler - handlers must not raise exceptions!
  ##

  if isNil(handler): return
  c.peerEvents.mgetOrPut(kind,
    initOrderedSet[PeerEventHandler]()).incl(handler)

proc removePeerEventHandler*(c: ConnManager,
                             handler: PeerEventHandler,
                             kind: PeerEvent) =
  c.peerEvents.withValue(kind, handlers) do:
    handlers[].excl(handler)

proc triggerPeerEvents*(c: ConnManager,
                        peerId: PeerID,
                        event: PeerEvent) {.async, gcsafe.} =

  if event notin c.peerEvents:
    return

  try:
    let count = c.connCount(peerId)
    if event == PeerEvent.Joined and count != 1:
      trace "peer already joined", peerId, event
      return
    elif event == PeerEvent.Left and count != 0:
      trace "peer still connected or already left", peerId, event
      return

    trace "triggering peer events", peerId, event

    var peerEvents: seq[Future[void]]
    for h in c.peerEvents[event]:
      peerEvents.add(h(peerId, event))

    checkFutures(await allFinished(peerEvents))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc: # handlers should not raise!
    warn "exception in triggerPeerEvents", exc = exc.msg, peerId

proc contains*(c: ConnManager, conn: Connection): bool =
  ## checks if a connection is being tracked by the
  ## connection manager
  ##

  if isNil(conn):
    return

  return conn in c.conns

proc contains*(c: ConnManager, peerId: PeerID): bool =
  c.connCount(peerId) > 0

proc contains*(c: ConnManager, muxer: Muxer): bool =
  ## checks if a muxer is being tracked by the connection
  ## manager
  ##

  if isNil(muxer):
    return

  let conn = muxer.connection
  if conn notin c:
    return

  if conn notin c.muxed:
    return

  return muxer == c.muxed[conn].muxer

proc closeMuxerHolder(muxerHolder: MuxerHolder) {.async.} =
  trace "Cleaning up muxer", m = muxerHolder.muxer

  await muxerHolder.muxer.close()
  if not(isNil(muxerHolder.handle)):
    await muxerHolder.handle # TODO noraises?
  trace "Cleaned up muxer", m = muxerHolder.muxer

proc delConn(c: ConnManager, conn: Connection) =
  c.conns.keepItIf(it != conn)
  if not isNil(conn.peerInfo):
    libp2p_peers.set(c.connCount( conn.peerInfo.peerId ).int64)
    trace "Removed connection", conn

proc cleanupConn(c: ConnManager, conn: Connection) {.async.} =
  ## clean connection's resources such as muxers and streams
  ##

  if isNil(conn):
    return

  var muxer = none(MuxerHolder)
  if not isNil(conn.peerInfo):
    # Remove connection from all tables without async breaks
    muxer = some(MuxerHolder())
    if not c.muxed.pop(conn, muxer.get()):
      muxer = none(MuxerHolder)

  delConn(c, conn)

  try:
    if muxer.isSome:
      await closeMuxerHolder(muxer.get())
  finally:
    await conn.close()

  trace "Connection cleaned up", conn

proc onClose(c: ConnManager, conn: Connection) {.async.} =
  ## connection close even handler
  ##
  ## triggers the connections resource cleanup
  ##

  try:
    await conn.join()
    trace "Connection closed, cleaning up", conn
    await c.cleanupConn(conn)
    c.connSemaphore.release()
  except CancelledError:
    # This is top-level procedure which will work as separate task, so it
    # do not need to propagate CancelledError.
    debug "Unexpected cancellation in connection manager's cleanup", conn
  except CatchableError as exc:
    debug "Unexpected exception in connection manager's cleanup",
          errMsg = exc.msg, conn

proc selectConn*(c: ConnManager,
                 peerId: PeerID,
                 dir: Direction): Connection =
  ## Select a connection for the provided peer and direction
  ##

  let conns = c.conns
    .filter(
      proc(conn: Connection): bool =
        (not isNil(conn.peerInfo) and conn.peerInfo.peerId == peerId)
    )
    .filterIt( it.dir == dir )

  if conns.len > 0:
    return conns[0]

proc selectConn*(c: ConnManager, peerId: PeerID): Connection =
  ## Select a connection for the provided giving priority
  ## to outgoing connections
  ##

  var conn = c.selectConn(peerId, Direction.Out)
  if isNil(conn):
    conn = c.selectConn(peerId, Direction.In)

  if isNil(conn):
    trace "connection not found", peerId

  return conn

proc selectMuxer*(c: ConnManager, conn: Connection): Muxer =
  ## select the muxer for the provided connection
  ##

  if isNil(conn):
    return

  if conn in c.muxed:
    return c.muxed[conn].muxer
  else:
    debug "no muxer for connection", conn

proc selectMuxer*(c: ConnManager,
                  peerId: PeerID,
                  dir: Direction): Muxer =
  ## select a muxer for a peer with the specified
  ## direction
  ##

  let conns = toSeq(c.muxed.keys).filterIt(
    it.peerInfo.peerId == peerId and it.dir == dir
  )

  if conns.len > 0:
    return c.selectMuxer(conns[0])

proc selectMuxer*(c: ConnManager, peerId: PeerID): Muxer =
  ## select a muxer for a peer
  ##

  var muxer = c.selectMuxer(peerId, Direction.Out)
  if isNil(muxer):
    muxer = c.selectMuxer(peerId, Direction.In)

  if isNil(muxer):
    trace "muxer not found", peerId

  return muxer

proc storeConn*(c: ConnManager, conn: Connection) {.async.} =
  ## store a connection
  ##

  if isNil(conn):
    raise newException(CatchableError, "connection cannot be nil")

  await c.connSemaphore.acquire()
  c.conns.add(conn)

  # Launch on close listener
  # All the errors are handled inside `onClose()` procedure.
  asyncSpawn c.onClose(conn)
  libp2p_peers.set(c.conns.len.int64)

  trace "Stored connection",
    conn, direction = $conn.dir, connections = c.conns.len

proc storeOutgoing*(c: ConnManager, conn: Connection): Future[void] =
  conn.dir = Direction.Out
  c.storeConn(conn)

proc storeIncoming*(c: ConnManager, conn: Connection): Future[void] =
  conn.dir = Direction.In
  c.storeConn(conn)

proc storeMuxer*(c: ConnManager,
                 muxer: Muxer,
                 handle: Future[void] = nil) =
  ## store the connection and muxer
  ##

  if isNil(muxer):
    raise newException(CatchableError, "muxer cannot be nil")

  if isNil(muxer.connection):
    raise newException(CatchableError, "muxer's connection cannot be nil")

  c.muxed[muxer.connection] = MuxerHolder(
    muxer: muxer,
    handle: handle)

  trace "Stored muxer",
    muxer, handle = not handle.isNil, connections = c.conns.len

proc getMuxedStream*(c: ConnManager,
                     peerId: PeerID,
                     dir: Direction): Future[Connection] {.async, gcsafe.} =
  ## get a muxed stream for the provided peer
  ## with the given direction
  ##

  let muxer = c.selectMuxer(peerId, dir)
  if not(isNil(muxer)):
    return await muxer.newStream()

proc getMuxedStream*(c: ConnManager,
                     peerId: PeerID): Future[Connection] {.async, gcsafe.} =
  ## get a muxed stream for the passed peer from any connection
  ##

  let muxer = c.selectMuxer(peerId)
  if not(isNil(muxer)):
    return await muxer.newStream()

proc getMuxedStream*(c: ConnManager,
                     conn: Connection): Future[Connection] {.async, gcsafe.} =
  ## get a muxed stream for the passed connection
  ##

  let muxer = c.selectMuxer(conn)
  if not(isNil(muxer)):
    return await muxer.newStream()

proc dropPeer*(c: ConnManager, peerId: PeerID) {.async.} =
  ## drop connections and cleanup resources for peer
  ##

  trace "Dropping peer", peerId
  # TODO: inflight connections for this peer can still be added
  # after upgrade
  let conns = c.conns.filter(
    proc(conn: Connection): bool =
      (not isNil(conn.peerInfo) and conn.peerInfo.peerId == peerId)
  )

  for conn in conns:
    trace  "Removing connection", conn
    delConn(c, conn)

  var muxers: seq[MuxerHolder]
  for conn in conns:
    if conn in c.muxed:
      muxers.add c.muxed[conn]
      c.muxed.del(conn)

  for muxer in muxers:
    await closeMuxerHolder(muxer)

  for conn in conns:
    await conn.close()
    trace "Dropped peer", peerId

proc close*(c: ConnManager) {.async.} =
  ## cleanup resources for the connection
  ## manager
  ##

  trace "Closing ConnManager"
  let conns = c.conns
  c.conns.setLen(0)

  let muxed = c.muxed
  c.muxed.clear()

  for _, muxer in muxed:
    await closeMuxerHolder(muxer)

  for conn in conns:
    await conn.close()

  trace "Closed ConnManager"
