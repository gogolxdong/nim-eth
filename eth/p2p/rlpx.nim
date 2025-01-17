{.push raises: [].}

import
  std/[tables, algorithm, deques, hashes, options, typetraits, os, endians, sequtils],
  stew/shims/macros, chronicles, nimcrypto/utils, chronos, metrics, stew/endians2,
  ".."/[rlp, common, keys, async_utils],
  ./private/p2p_types, "."/[kademlia, auth, rlpxcrypt, enode, p2p_protocol_dsl]

const
  allowObsoletedChunkedMessages = defined(chunked_rlpx_enabled)

when useSnappy:
  import snappy
  const devp2pSnappyVersion* = 5

export
  options, p2pProtocol, rlp, chronicles

declarePublicGauge rlpx_connected_peers,
  "Number of connected peers in the pool"

declarePublicCounter rlpx_connect_success,
  "Number of successfull rlpx connects"

declarePublicCounter rlpx_connect_failure,
  "Number of rlpx connects that failed", labels = ["reason"]

declarePublicCounter rlpx_accept_success,
  "Number of successful rlpx accepted peers"

declarePublicCounter rlpx_accept_failure,
  "Number of rlpx accept attempts that failed", labels = ["reason"]

logScope:
  topics = "eth p2p rlpx"

type
  ResponderWithId*[MsgType] = object
    peer*: Peer
    reqId*: int

  ResponderWithoutId*[MsgType] = distinct Peer

  # We need these two types in rlpx/devp2p as no parameters or single parameters
  # are not getting encoded in an rlp list.
  # TODO: we could generalize this in the protocol dsl but it would need an
  # `alwaysList` flag as not every protocol expects lists in these cases.
  EmptyList = object
  DisconnectionReasonList = object
    value: DisconnectionReason

proc read(rlp: var Rlp; T: type DisconnectionReasonList): T
    {.gcsafe, raises: [RlpError].} =
  ## Rlp mixin: `DisconnectionReasonList` parser

  if rlp.isList:
    # Be strict here: The expression `rlp.read(DisconnectionReasonList)`
    # accepts lists with at least one item. The array expression wants
    # exactly one item.
    if rlp.rawData.len < 3:
      # avoids looping through all items when parsing for an overlarge array
      return DisconnectionReasonList(
        value: rlp.read(array[1,DisconnectionReason])[0])

  # Also accepted: a single byte reason code. Is is typically used
  # by variants of the reference implementation `Geth`
  elif rlp.blobLen <= 1:
    return DisconnectionReasonList(
      value: rlp.read(DisconnectionReason))

  # Also accepted: a blob of a list (aka object) of reason code. It is
  # used by `bor`, a `geth` fork
  elif rlp.blobLen < 4:
    var subList = rlp.toBytes.rlpFromBytes
    if subList.isList:
      # Ditto, see above.
      return DisconnectionReasonList(
        value: subList.read(array[1,DisconnectionReason])[0])

  raise newException(RlpTypeMismatch, "Single entry list expected")


const
  devp2pVersion* = 4
  maxMsgSize = 1024 * 1024 * 10
  HandshakeTimeout = MessageTimeout

include p2p_tracing

when tracingEnabled:
  import
    eth/common/eth_types_json_serialization

  export
    init, writeValue, getOutput

proc init*[MsgName](T: type ResponderWithId[MsgName],
                    peer: Peer, reqId: int): T =
  T(peer: peer, reqId: reqId)

proc init*[MsgName](T: type ResponderWithoutId[MsgName], peer: Peer): T =
  T(peer)

chronicles.formatIt(Peer): $(it.remote)

include p2p_backends_helpers

proc requestResolver[MsgType](msg: pointer, future: FutureBase) {.gcsafe.} =
  var f = Future[Option[MsgType]](future)
  if not f.finished:
    if msg != nil:
      f.complete some(cast[ptr MsgType](msg)[])
    else:
      f.complete none(MsgType)
  else:
    if msg != nil:
      try:
        if f.read.isSome:
          doAssert false, "trying to resolve a request twice"
        else:
          doAssert false, "trying to resolve a timed out request with a value"
      except CatchableError as e:
        debug "Exception in requestResolver()", exc = e.name, err = e.msg
    else:
      try:
        if not f.read.isSome:
          doAssert false, "a request timed out twice"
      except TransportOsError as e:
        trace "TransportOsError during request", err = e.msg
      except TransportError:
        trace "Transport got closed during request"
      except CatchableError as e:
        debug "Exception in requestResolver()", exc = e.name, err = e.msg

proc linkSendFailureToReqFuture[S, R](sendFut: Future[S], resFut: Future[R]) =
  sendFut.addCallback() do (arg: pointer):
    if not resFut.finished:
      if sendFut.failed:
        resFut.fail(sendFut.error)

proc messagePrinter[MsgType](msg: pointer): string {.gcsafe.} =
  result = ""
  # TODO: uncommenting the line below increases the compile-time
  # tremendously (for reasons not yet known)
  # result = $(cast[ptr MsgType](msg)[])

proc disconnect*(peer: Peer, reason: DisconnectionReason, notifyOtherPeer = false) {.gcsafe, async.}

template raisePeerDisconnected(msg: string, r: DisconnectionReason) =
  var e = newException(PeerDisconnected, msg)
  e.reason = r
  raise e

proc disconnectAndRaise(peer: Peer,
                        reason: DisconnectionReason,
                        msg: string) {.async.} =
  let r = reason
  await peer.disconnect(r)
  raisePeerDisconnected(msg, r)

proc handshakeImpl[T](peer: Peer,
                      sendFut: Future[void],
                      responseFut: Future[T],
                      timeout: Duration): Future[T] {.async.} =
  sendFut.addCallback do (arg: pointer) {.gcsafe.}:
    if sendFut.failed:
      info "Handshake message not delivered", peer

  doAssert timeout.milliseconds > 0
  yield responseFut or sleepAsync(timeout)
  if not responseFut.finished:
    await disconnectAndRaise(peer, HandshakeTimeout,
                             "Protocol handshake was not received in time.")
  elif responseFut.failed:
    raise responseFut.error
  else:
    return responseFut.read

var gDevp2pInfo: ProtocolInfo
template devp2pInfo: auto = {.gcsafe.}: gDevp2pInfo

# Dispatcher
#

proc hash(d: Dispatcher): int =
  hash(d.protocolOffsets)

proc `==`(lhs, rhs: Dispatcher): bool =
  lhs.activeProtocols == rhs.activeProtocols

proc describeProtocols(d: Dispatcher): string =
  result = ""
  for protocol in d.activeProtocols:
    if result.len != 0: result.add(',')
    for c in protocol.name: result.add(c)

proc numProtocols(d: Dispatcher): int =
  d.activeProtocols.len

proc getDispatcher(node: EthereumNode,
                   otherPeerCapabilities: openArray[Capability]): Dispatcher =
  # TODO: sub-optimal solution until progress is made here:
  # https://github.com/nim-lang/Nim/issues/7457
  # We should be able to find an existing dispatcher without allocating a new one
  info "getDispatcher", nodeProtocols=node.protocols.mapIt((it.name,it.version, it.index))
  new result
  newSeq(result.protocolOffsets, allProtocols.len)
  result.protocolOffsets.fill -1

  var nextUserMsgId = 0x10

  for localProtocol in node.protocols:
    let idx = localProtocol.index
    echo idx
    block findMatchingProtocol:
      for remoteCapability in otherPeerCapabilities:
        echo localProtocol.name, "==", remoteCapability.name, " ",localProtocol.version, "==",remoteCapability.version
        if localProtocol.name == remoteCapability.name and
           localProtocol.version == remoteCapability.version:
          result.protocolOffsets[idx] = nextUserMsgId
          nextUserMsgId += localProtocol.messages.len
          break findMatchingProtocol

  template copyTo(src, dest; index: int) =
    for i in 0 ..< src.len:
      dest[index + i] = addr src[i]

  result.messages = newSeq[ptr MessageInfo](nextUserMsgId)
  devp2pInfo.messages.copyTo(result.messages, 0)

  for localProtocol in node.protocols:
    let idx = localProtocol.index
    if result.protocolOffsets[idx] != -1:
      echo "activeProtocols.add ", localProtocol.name, " ", localProtocol.version
      result.activeProtocols.add localProtocol
      localProtocol.messages.copyTo(result.messages,
                                    result.protocolOffsets[idx])

proc getMsgName*(peer: Peer, msgId: int): string =
  if not peer.dispatcher.isNil and
     msgId < peer.dispatcher.messages.len and
     not peer.dispatcher.messages[msgId].isNil:
    return peer.dispatcher.messages[msgId].name
  else:
    return case msgId
           of 0: "hello"
           of 1: "disconnect"
           of 2: "ping"
           of 3: "pong"
           else: $msgId

proc getMsgMetadata*(peer: Peer, msgId: int): (ProtocolInfo, ptr MessageInfo) =
  doAssert msgId >= 0

  if msgId <= devp2pInfo.messages[^1].id:
    return (devp2pInfo, addr devp2pInfo.messages[msgId])

  if msgId < peer.dispatcher.messages.len:
    for i in 0 ..< allProtocols.len:
      let offset = peer.dispatcher.protocolOffsets[i]
      if offset != -1 and
         offset + allProtocols[i].messages[^1].id >= msgId:
        return (allProtocols[i], peer.dispatcher.messages[msgId])

# Protocol info objects
#

proc initProtocol(name: string, version: int,
                  peerInit: PeerStateInitializer,
                  networkInit: NetworkStateInitializer): ProtocolInfoObj =
  result.name = name
  result.version = version
  result.messages = @[]
  result.peerStateInitializer = peerInit
  result.networkStateInitializer = networkInit

proc setEventHandlers(p: ProtocolInfo,
                      handshake: HandshakeStep,
                      disconnectHandler: DisconnectionHandler) =
  p.handshake = handshake
  p.disconnectHandler = disconnectHandler

func asCapability*(p: ProtocolInfo): Capability =
  result.name = p.name
  result.version = p.version

proc cmp*(lhs, rhs: ProtocolInfo): int =
  return cmp(lhs.name, rhs.name)

proc nextMsgResolver[MsgType](msgData: Rlp, future: FutureBase)
    {.gcsafe, raises: [RlpError].} =
  var reader = msgData
  Future[MsgType](future).complete reader.readRecordType(MsgType,
    MsgType.rlpFieldsCount > 1)

proc registerMsg(protocol: ProtocolInfo,
                 id: int, name: string,
                 thunk: ThunkProc,
                 printer: MessageContentPrinter,
                 requestResolver: RequestResolver,
                 nextMsgResolver: NextMsgResolver) =
  if protocol.messages.len <= id:
    protocol.messages.setLen(id + 1)
  protocol.messages[id] = MessageInfo(id: id,
                                      name: name,
                                      thunk: thunk,
                                      printer: printer,
                                      requestResolver: requestResolver,
                                      nextMsgResolver: nextMsgResolver)

proc registerProtocol(protocol: ProtocolInfo) =
  # TODO: This can be done at compile-time in the future
  if protocol.name != "p2p":
    let pos = lowerBound(gProtocols, protocol)
    gProtocols.insert(protocol, pos)
    for i in 0 ..< gProtocols.len:
      gProtocols[i].index = i
  else:
    gDevp2pInfo = protocol

# Message composition and encryption
#

proc perPeerMsgIdImpl(peer: Peer, proto: ProtocolInfo, msgId: int): int =
  result = msgId
  if not peer.dispatcher.isNil:
    result += peer.dispatcher.protocolOffsets[proto.index]

template getPeer(peer: Peer): auto = peer
template getPeer(responder: ResponderWithId): auto = responder.peer
template getPeer(responder: ResponderWithoutId): auto = Peer(responder)

proc supports*(peer: Peer, proto: ProtocolInfo): bool =
  peer.dispatcher.protocolOffsets[proto.index] != -1

proc supports*(peer: Peer, Protocol: type): bool =
  ## Checks whether a Peer supports a particular protocol
  peer.supports(Protocol.protocolInfo)

template perPeerMsgId(peer: Peer, MsgType: type): int =
  perPeerMsgIdImpl(peer, MsgType.msgProtocol.protocolInfo, MsgType.msgId)

proc invokeThunk*(peer: Peer, msgId: int, msgData: var Rlp): Future[void]
    {.raises: [UnsupportedMessageError, RlpError].} =
  template invalidIdError: untyped =
    raise newException(UnsupportedMessageError,
      "RLPx message with an invalid id " & $msgId &
      " on a connection supporting " & peer.dispatcher.describeProtocols)

  # msgId can be negative as it has int as type and gets decoded from rlp
  if msgId >= peer.dispatcher.messages.len or msgId < 0: invalidIdError()
  if peer.dispatcher.messages[msgId].isNil: invalidIdError()

  let thunk = peer.dispatcher.messages[msgId].thunk
  if thunk == nil: invalidIdError()

  return thunk(peer, msgId, msgData)

template compressMsg(peer: Peer, data: seq[byte]): seq[byte] =
  when useSnappy:
    if peer.snappyEnabled:
      snappy.encode(data)
    else: data
  else:
    data

proc sendMsg*(peer: Peer, data: seq[byte]) {.gcsafe, async.} =
  var cipherText = encryptMsg(peer.compressMsg(data), peer.secretsState)
  try:
    var res = await peer.transport.write(cipherText)
    if res != len(cipherText):
      # This is ECONNRESET or EPIPE case when remote peer disconnected.
      await peer.disconnect(TcpError)
  except CatchableError as e:
    await peer.disconnect(TcpError)
    raise e

proc send*[Msg](peer: Peer, msg: Msg): Future[void] =
  logSentMsg(peer, msg)

  var rlpWriter = initRlpWriter()
  rlpWriter.append perPeerMsgId(peer, Msg)
  rlpWriter.appendRecordType(msg, Msg.rlpFieldsCount > 1)
  peer.sendMsg rlpWriter.finish

proc registerRequest(peer: Peer,
                     timeout: Duration,
                     responseFuture: FutureBase,
                     responseMsgId: int): int =
  inc peer.lastReqId
  result = peer.lastReqId

  let timeoutAt = Moment.fromNow(timeout)
  let req = OutstandingRequest(id: result,
                               future: responseFuture,
                               timeoutAt: timeoutAt)
  peer.outstandingRequests[responseMsgId].addLast req

  doAssert(not peer.dispatcher.isNil)
  let requestResolver = peer.dispatcher.messages[responseMsgId].requestResolver
  proc timeoutExpired(udata: pointer) {.gcsafe.} =
    requestResolver(nil, responseFuture)

  discard setTimer(timeoutAt, timeoutExpired, nil)

proc resolveResponseFuture(peer: Peer, msgId: int, msg: pointer, reqId: int) =
  logScope:
    msg = peer.dispatcher.messages[msgId].name
    msgContents = peer.dispatcher.messages[msgId].printer(msg)
    receivedReqId = reqId
    remotePeer = peer.remote

  template resolve(future) =
    (peer.dispatcher.messages[msgId].requestResolver)(msg, future)

  template outstandingReqs: auto =
    peer.outstandingRequests[msgId]

  if reqId == -1:
    # XXX: This is a response from an ETH-like protocol that doesn't feature
    # request IDs. Handling the response is quite tricky here because this may
    # be a late response to an already timed out request or a valid response
    # from a more recent one.
    #
    # We can increase the robustness by recording enough features of the
    # request so we can recognize the matching response, but this is not very
    # easy to do because our peers are allowed to send partial responses.
    #
    # A more generally robust approach is to maintain a set of the wanted
    # data items and then to periodically look for items that have been
    # requested long time ago, but are still missing. New requests can be
    # issues for such items potentially from another random peer.
    var expiredRequests = 0
    for req in outstandingReqs:
      if not req.future.finished: break
      inc expiredRequests
    outstandingReqs.shrink(fromFirst = expiredRequests)
    if outstandingReqs.len > 0:
      let oldestReq = outstandingReqs.popFirst
      resolve oldestReq.future
    else:
      trace "late or duplicate reply for a RLPx request"
  else:
    # TODO: This is not completely sound because we are still using a global
    # `reqId` sequence (the problem is that we might get a response ID that
    # matches a request ID for a different type of request). To make the code
    # correct, we can use a separate sequence per response type, but we have
    # to first verify that the other Ethereum clients are supporting this
    # correctly (because then, we'll be reusing the same reqIds for different
    # types of requests). Alternatively, we can assign a separate interval in
    # the `reqId` space for each type of response.
    if reqId > peer.lastReqId:
      warn "RLPx response without a matching request"
      return

    var idx = 0
    while idx < outstandingReqs.len:
      template req: auto = outstandingReqs()[idx]

      if req.future.finished:
        doAssert req.timeoutAt <= Moment.now()
        # Here we'll remove the expired request by swapping
        # it with the last one in the deque (if necessary):
        if idx != outstandingReqs.len - 1:
          req = outstandingReqs.popLast
          continue
        else:
          outstandingReqs.shrink(fromLast = 1)
          # This was the last item, so we don't have any
          # more work to do:
          return

      if req.id == reqId:
        resolve req.future
        # Here we'll remove the found request by swapping
        # it with the last one in the deque (if necessary):
        if idx != outstandingReqs.len - 1:
          req = outstandingReqs.popLast
        else:
          outstandingReqs.shrink(fromLast = 1)
        return

      inc idx

    debug "late or duplicate reply for a RLPx request"

proc getRlpxHeaderData(header: RlpxHeader): (int,int,int) =
  ## Helper for `recvMsg()`
  # This is insane. Some clients like Nethermind use the now obsoleted
  # chunked message frame protocol, see
  # github.com/ethereum/devp2p/commit/6504d410bc4b8dda2b43941e1cb48c804b90cf22.
  result = (-1, -1, 0)
  proc datagramSize: int =
    # For logging only
    (header[0].int shl 16) or (header[1].int shl 8) or header[1].int
  try:
    let optsLen = max(0, header[3].int - 0xc0)
    var hdrData = header[4 ..< 4 + optsLen].rlpFromBytes
    result[0] = hdrData.read(int)   # capability ID
    result[1] = hdrData.read(int)   # context ID
    if hdrData.isBlob:
      result[2] = hdrData.read(int) # total packet size
      trace "RLPx message first chunked header-data",
        capabilityId = result[0],
        contextId = result[1],
        totalPacketSize = result[2],
        datagramSize = datagramSize()
    #[
    elif 0 < result[1]:
      # This should be all zero according to latest specs
      trace "RLPx message chunked next header-data",
        capabilityId = result[0],
        contextId = result[1],
        datagramSize = datagramSize()
    ]#
  except:
    error "RLPx message header-data options, parse error",
      capabilityId = result[0],
      contextId = result[1],
      totalPacketSize = result[2],
      datagramSize = datagramSize()
    result = (-1, -1, -1)

proc recvMsg*(peer: Peer): Future[tuple[msgId: int, msgData: Rlp]] {.async.} =
  var headerBytes: array[32, byte]
  await peer.transport.readExactly(addr headerBytes[0], 32)

  var msgSize: int
  var msgHeader: RlpxHeader
  if decryptHeaderAndGetMsgSize(peer.secretsState,headerBytes, msgSize, msgHeader).isErr():
    info "Cannot decrypt RLPx frame header"
    await peer.disconnectAndRaise(BreachOfProtocol,
                                  "Cannot decrypt RLPx frame header")

  if msgSize > maxMsgSize:
    info "RLPx message exceeds maximum size"
    await peer.disconnectAndRaise(BreachOfProtocol, "RLPx message exceeds maximum size")

  let remainingBytes = encryptedLength(msgSize) - 32
  # TODO: Migrate this to a thread-local seq
  # JACEK:
  #  or pass it in, allowing the caller to choose - they'll likely be in a
  #  better position to decide if buffer should be reused or not. this will
  #  also be useful for chunked messages where part of the buffer may have
  #  been processed and needs filling in
  var encryptedBytes = newSeq[byte](remainingBytes)
  await peer.transport.readExactly(addr encryptedBytes[0], len(encryptedBytes))

  let decryptedMaxLength = decryptedLength(msgSize)
  var
    decryptedBytes = newSeq[byte](decryptedMaxLength)
    decryptedBytesCount = 0

  if decryptBody(peer.secretsState, encryptedBytes, msgSize,
                 decryptedBytes, decryptedBytesCount).isErr():
    info "Cannot decrypt RLPx frame body"
    await peer.disconnectAndRaise(BreachOfProtocol,
                                  "Cannot decrypt RLPx frame body")

  decryptedBytes.setLen(decryptedBytesCount)

  when useSnappy:
    if peer.snappyEnabled:
      decryptedBytes = snappy.decode(decryptedBytes, maxMsgSize)
      if decryptedBytes.len == 0:
        info "Snappy uncompress encountered malformed data"
        await peer.disconnectAndRaise(BreachOfProtocol,
                                      "Snappy uncompress encountered malformed data")

  # Check embedded header-data for start of an obsoleted chunked message.
  #
  # The current RLPx requirements need all triple entries <= 0, see
  # github.com/ethereum/devp2p/blob/master/rlpx.md#framing
  let (capaId, ctxId, totalMsgSize) = msgHeader.getRlpxHeaderData

  when not allowObsoletedChunkedMessages:
    # Note that the check should come *before* the `msgId` is read. For
    # instance, if this is a malformed packet, then the `msgId` might be
    # random which in turn might try to access a `peer.dispatcher.messages[]`
    # slot with a `nil` entry.
    if 0 < capaId or 0 < ctxId or 0 < totalMsgSize:
      info "Rejected obsoleted chunked message header"
      await peer.disconnectAndRaise(
        BreachOfProtocol, "Rejected obsoleted chunked message header")

  var rlp = rlpFromBytes(decryptedBytes)

  var msgId: int32
  try:
    # int32 as this seems more than big enough for the amount of msgIds
    msgId = rlp.read(int32)
    result = (msgId.int, rlp)
    info "recvMsg", msgId=msgId, result=result
  except RlpError:
    info "Cannot read RLPx message id"
    await peer.disconnectAndRaise(BreachOfProtocol, "Cannot read RLPx message id")

  info "recvMsg",allowObsoletedChunkedMessages=allowObsoletedChunkedMessages
  when allowObsoletedChunkedMessages:
    # Snappy with obsolete chunked RLPx message datagrams is unsupported here
    when useSnappy:
      if peer.snappyEnabled:
        return

    # This also covers totalMessageSize <= 0
    if totalMsgSize <= msgSize:
      return

    # Loop over chunked RLPx datagram fragments
    var moreData = totalMsgSize - msgSize
    while 0 < moreData:

      # Load and parse next header
      block:
        await peer.transport.readExactly(addr headerBytes[0], 32)
        if decryptHeaderAndGetMsgSize(peer.secretsState,
                                      headerBytes, msgSize, msgHeader).isErr():
          info "RLPx next chunked header-data failed",
            peer, msgId, ctxId, maxSize = moreData
          await peer.disconnectAndRaise(
            BreachOfProtocol, "Cannot decrypt next chunked RLPx header")

      # Verify that this is really the next chunk
      block:
        let (_, ctyId, totalSize) = msgHeader.getRlpxHeaderData
        if ctyId != ctxId or 0 < totalSize:
          info "Malformed RLPx next chunked header-data",
            peer, msgId, msgSize, ctxtId = ctyId, expCtxId = ctxId, totalSize
          await peer.disconnectAndRaise(
            BreachOfProtocol, "Malformed next chunked RLPx header")

      # Append payload to `decryptedBytes` collector
      block:
        var encBytes = newSeq[byte](msgSize.encryptedLength - 32)
        await peer.transport.readExactly(addr encBytes[0], encBytes.len)
        var
          dcrBytes = newSeq[byte](msgSize.decryptedLength)
          dcrBytesCount = 0
        # TODO: This should be improved by passing a reference into
        # `decryptedBytes` where to append the data.
        if decryptBody(peer.secretsState, encBytes, msgSize,
                       dcrBytes, dcrBytesCount).isErr():
          await peer.disconnectAndRaise(
            BreachOfProtocol, "Cannot decrypt next chunked RLPx frame body")
        decryptedBytes.add dcrBytes[0 ..< dcrBytesCount]
        moreData -= msgSize
        #[
        trace "RLPx next chunked datagram fragment",
          peer, msgId = result[0], ctxId, msgSize, moreData, totalMsgSize,
          dcrBytesCount, payloadSoFar = decryptedBytes.len
        ]#

      # End While

    if moreData != 0:
      await peer.disconnectAndRaise(
        BreachOfProtocol, "Malformed assembly of chunked RLPx message")

    # Pass back extended message (first entry remains `msgId`)
    result[1] = decryptedBytes.rlpFromBytes
    result[1].position = rlp.position

    info "RLPx chunked datagram payload",
      peer, msgId, ctxId, totalMsgSize, moreData, payload = decryptedBytes.len

    # End `allowObsoletedChunkedMessages`


proc checkedRlpRead(peer: Peer, r: var Rlp, MsgType: type):
    auto {.raises: [RlpError].} =
  when defined(release):
    return r.read(MsgType)
  else:
    try:
      return r.read(MsgType)
    except rlp.RlpError as e:
      debug "Failed rlp.read",
            peer = peer,
            dataType = MsgType.name,
            exception = e.msg
            # rlpData = r.inspect -- don't use (might crash)

      raise e

proc waitSingleMsg(peer: Peer, MsgType: type): Future[MsgType] {.async.} =
  let wantedId = peer.perPeerMsgId(MsgType)
  info "waitSingleMsg", wantedId=wantedId
  while true:
    var nextMsgId: int
    var nextMsgData: Rlp
    try:
      (nextMsgId, nextMsgData) = await peer.recvMsg()
    except :
      var message = getCurrentExceptionMsg()
      info "recvMsg", err=message
      await peer.disconnectAndRaise(BreachOfProtocol, message)


    if nextMsgId == wantedId:
      try:
        result = checkedRlpRead(peer, nextMsgData, MsgType)
        logReceivedMsg(peer, result)
        return
      except rlp.RlpError:
        info "waitSingleMsg",err = BreachOfProtocol
        await peer.disconnectAndRaise(BreachOfProtocol, "Invalid RLPx message body")

    elif nextMsgId == 1: # p2p.disconnect
      let reasonList = nextMsgData.read(DisconnectionReasonList)
      let reason = reasonList.value
      await peer.disconnect(reason)
      info "disconnect message received in waitSingleMsg", reason, peer
      raisePeerDisconnected("Unexpected disconnect", reason)
    else:
      info "Dropped RLPX message",
           msg = peer.dispatcher.messages[nextMsgId].name
      # TODO: This is breach of protocol?

proc nextMsg*(peer: Peer, MsgType: type): Future[MsgType] =
  ## This procs awaits a specific RLPx message.
  ## Any messages received while waiting will be dispatched to their
  ## respective handlers. The designated message handler will also run
  ## to completion before the future returned by `nextMsg` is resolved.
  let wantedId = peer.perPeerMsgId(MsgType)
  let f = peer.awaitedMessages[wantedId]
  if not f.isNil:
    return Future[MsgType](f)

  initFuture result
  peer.awaitedMessages[wantedId] = result

# Known fatal errors are handled inside dispatchMessages.
# Errors we are currently unaware of are caught in the dispatchMessages
# callback. There they will be logged if CatchableError and quit on Defect.
# Non fatal errors such as the current CatchableError could be moved and
# handled a layer lower for clarity (and consistency), as also the actual
# message handler code as the TODO mentions already.
proc dispatchMessages*(peer: Peer) {.async.} =
  while peer.connectionState notin {Disconnecting, Disconnected}:
    var msgId: int
    var msgData: Rlp
    try:
      (msgId, msgData) = await peer.recvMsg()
    except TransportError as e:
      info "dispatchMessages", err=e.msg
      case peer.connectionState
      of Connected:
        info "Dropped connection", peer, error= e.msg
        await peer.disconnect(ClientQuitting, false)
        return
      of Disconnecting, Disconnected:
        info "Disconnecting Disconnecting", peer, error= e.msg
        return
      else:
        return
    except PeerDisconnected as e:
      info "dispatchMessages", err=e.msg
      return
    
    try:
      info "dispatchMessages", invokeThunk=msgId
      await peer.invokeThunk(msgId, msgData)
    except RlpError:
      info "RlpError, ending dispatchMessages loop", peer, msg = peer.getMsgName(msgId)
      await peer.disconnect(BreachOfProtocol, true)
      return
    except CatchableError as e:
      info "Error while handling RLPx message", peer,
        msg = peer.getMsgName(msgId), err = e.msg

    if msgId >= 0 and msgId < peer.awaitedMessages.len and peer.awaitedMessages[msgId] != nil:
      let msgInfo = peer.dispatcher.messages[msgId]
      try:
        (msgInfo.nextMsgResolver)(msgData, peer.awaitedMessages[msgId])
      except CatchableError as e:
        info "nextMsg resolver failed, ending dispatchMessages loop", peer, err = e.msg
        await peer.disconnect(BreachOfProtocol, true)
        return
      peer.awaitedMessages[msgId] = nil

proc p2pProtocolBackendImpl*(protocol: P2PProtocol): Backend =
  let
    resultIdent = ident "result"
    Peer = bindSym "Peer"
    EthereumNode = bindSym "EthereumNode"

    initRlpWriter = bindSym "initRlpWriter"
    append = bindSym("append", brForceOpen)
    read = bindSym("read", brForceOpen)
    checkedRlpRead = bindSym "checkedRlpRead"
    startList = bindSym "startList"
    tryEnterList = bindSym "tryEnterList"
    finish = bindSym "finish"

    messagePrinter = bindSym "messagePrinter"
    nextMsgResolver = bindSym "nextMsgResolver"
    registerRequest = bindSym "registerRequest"
    requestResolver = bindSym "requestResolver"
    resolveResponseFuture = bindSym "resolveResponseFuture"
    sendMsg = bindSym "sendMsg"
    nextMsg = bindSym "nextMsg"
    initProtocol = bindSym"initProtocol"
    registerMsg = bindSym "registerMsg"
    perPeerMsgId = bindSym "perPeerMsgId"
    perPeerMsgIdImpl = bindSym "perPeerMsgIdImpl"
    linkSendFailureToReqFuture = bindSym "linkSendFailureToReqFuture"
    handshakeImpl = bindSym "handshakeImpl"

    ResponderWithId = bindSym "ResponderWithId"
    ResponderWithoutId = bindSym "ResponderWithoutId"

    isSubprotocol = protocol.rlpxName != "p2p"

  if protocol.rlpxName.len == 0: protocol.rlpxName = protocol.name
  # By convention, all Ethereum protocol names have at least 3 characters.
  doAssert protocol.rlpxName.len >= 3

  new result

  result.registerProtocol = bindSym "registerProtocol"
  result.setEventHandlers = bindSym "setEventHandlers"
  result.PeerType = Peer
  result.NetworkType = EthereumNode
  result.ResponderType = if protocol.useRequestIds: ResponderWithId
                         else: ResponderWithoutId

  result.implementMsg = proc (msg: Message) =
    var
      msgId = msg.id
      msgIdent = msg.ident
      msgName = $msgIdent
      msgRecName = msg.recName
      responseMsgId = if msg.response != nil: msg.response.id else: -1
      ResponseRecord = if msg.response != nil: msg.response.recName else: nil
      hasReqId = msg.hasReqId
      protocol = msg.protocol
      userPragmas = msg.procDef.pragma

      # variables used in the sending procs
      peerOrResponder = ident"peerOrResponder"
      rlpWriter = ident"writer"
      perPeerMsgIdVar  = ident"perPeerMsgId"

      # variables used in the receiving procs
      receivedRlp = ident"rlp"
      receivedMsg = ident"msg"

    var
      readParams = newNimNode(nnkStmtList)
      paramsToWrite = newSeq[NimNode](0)
      appendParams = newNimNode(nnkStmtList)

    if hasReqId:
      # Messages using request Ids
      readParams.add quote do:
        let `reqIdVar` = `read`(`receivedRlp`, int)

    case msg.kind
    of msgRequest:
      let reqToResponseOffset = responseMsgId - msgId
      let responseMsgId = quote do: `perPeerMsgIdVar` + `reqToResponseOffset`

      # Each request is registered so we can resolve it when the response
      # arrives. There are two types of protocols: LES-like protocols use
      # explicit `reqId` sent over the wire, while the ETH wire protocol
      # assumes there is one outstanding request at a time (if there are
      # multiple requests we'll resolve them in FIFO order).
      let registerRequestCall = newCall(registerRequest, peerVar,
                                                         timeoutVar,
                                                         resultIdent,
                                                         responseMsgId)
      if hasReqId:
        appendParams.add quote do:
          initFuture `resultIdent`
          let `reqIdVar` = `registerRequestCall`
        paramsToWrite.add reqIdVar
      else:
        appendParams.add quote do:
          initFuture `resultIdent`
          discard `registerRequestCall`

    of msgResponse:
      if hasReqId:
        paramsToWrite.add newDotExpr(peerOrResponder, reqIdVar)

    of msgHandshake, msgNotification: discard

    for param, paramType in msg.procDef.typedParams(skip = 1):
      # This is a fragment of the sending proc that
      # serializes each of the passed parameters:
      paramsToWrite.add param

      # The received RLP data is deserialized to a local variable of
      # the message-specific type. This is done field by field here:
      let msgNameLit = newLit(msgName)
      readParams.add quote do:
        `receivedMsg`.`param` = `checkedRlpRead`(`peerVar`, `receivedRlp`, `paramType`)

    let
      paramCount = paramsToWrite.len
      readParamsPrelude = if paramCount > 1: newCall(tryEnterList, receivedRlp)
                          else: newStmtList()

    when tracingEnabled:
      readParams.add newCall(bindSym"logReceivedMsg", peerVar, receivedMsg)

    let callResolvedResponseFuture = if msg.kind == msgResponse:
      newCall(resolveResponseFuture,
              peerVar,
              newCall(perPeerMsgId, peerVar, msgRecName),
              newCall("addr", receivedMsg),
              if hasReqId: reqIdVar else: newLit(-1))
    else:
      newStmtList()

    var userHandlerParams = @[peerVar]
    if hasReqId: userHandlerParams.add reqIdVar

    let
      awaitUserHandler = msg.genAwaitUserHandler(receivedMsg, userHandlerParams)
      thunkName = ident(msgName & "Thunk")

    msg.defineThunk quote do:
      proc `thunkName`(`peerVar`: `Peer`, _: int, data: Rlp)
          # Fun error if you just use `RlpError` instead of `rlp.RlpError`:
          # "Error: type expected, but got symbol 'RlpError' of kind 'EnumField'"
          {.async, gcsafe, raises: [rlp.RlpError].} =
        var `receivedRlp` = data
        var `receivedMsg` {.noinit.}: `msgRecName`
        `readParamsPrelude`
        `readParams`
        `awaitUserHandler`
        `callResolvedResponseFuture`

    var sendProc = msg.createSendProc(isRawSender = (msg.kind == msgHandshake))
    sendProc.def.params[1][0] = peerOrResponder

    let
      msgBytes = ident"msgBytes"
      finalizeRequest = quote do:
        let `msgBytes` = `finish`(`rlpWriter`)

    var sendCall = newCall(sendMsg, peerVar, msgBytes)
    let senderEpilogue = if msg.kind == msgRequest:
      # In RLPx requests, the returned future was allocated here and passed
      # to `registerRequest`. It's already assigned to the result variable
      # of the proc, so we just wait for the sending operation to complete
      # and we return in a normal way. (the waiting is done, so we can catch
      # any possible errors).
      quote: `linkSendFailureToReqFuture`(`sendCall`, `resultIdent`)
    else:
      # In normal RLPx messages, we are returning the future returned by the
      # `sendMsg` call.
      quote: return `sendCall`

    let perPeerMsgIdValue = if isSubprotocol:
      newCall(perPeerMsgIdImpl, peerVar, protocol.protocolInfoVar, newLit(msgId))
    else:
      newLit(msgId)

    if paramCount > 1:
      # In case there are more than 1 parameter,
      # the params must be wrapped in a list:
      appendParams = newStmtList(
        newCall(startList, rlpWriter, newLit(paramCount)),
        appendParams)

    for param in paramsToWrite:
      appendParams.add newCall(append, rlpWriter, param)

    let initWriter = quote do:
      var `rlpWriter` = `initRlpWriter`()
      const `perProtocolMsgIdVar` = `msgId`
      let `perPeerMsgIdVar` = `perPeerMsgIdValue`
      `append`(`rlpWriter`, `perPeerMsgIdVar`)

    when tracingEnabled:
      appendParams.add logSentMsgFields(peerVar, protocol, msgId, paramsToWrite)

    # let paramCountNode = newLit(paramCount)
    sendProc.setBody quote do:
      let `peerVar` = getPeer(`peerOrResponder`)
      `initWriter`
      `appendParams`
      `finalizeRequest`
      `senderEpilogue`

    if msg.kind == msgHandshake:
      discard msg.createHandshakeTemplate(sendProc.def.name, handshakeImpl, nextMsg)

    protocol.outProcRegistrations.add(
      newCall(registerMsg,
              protocol.protocolInfoVar,
              newLit(msgId),
              newLit(msgName),
              thunkName,
              newTree(nnkBracketExpr, messagePrinter, msgRecName),
              newTree(nnkBracketExpr, requestResolver, msgRecName),
              newTree(nnkBracketExpr, nextMsgResolver, msgRecName)))

  result.implementProtocolInit = proc (protocol: P2PProtocol): NimNode =
    return newCall(initProtocol,
                   newLit(protocol.rlpxName),
                   newLit(protocol.version),
                   protocol.peerInit, protocol.netInit)

p2pProtocol DevP2P(version = 5, rlpxName = "p2p"):
  proc hello(peer: Peer,
             version: uint,
             clientId: string,
             capabilities: seq[Capability],
             listenPort: uint,
             nodeId: array[RawPublicKeySize, byte])

  proc sendDisconnectMsg(peer: Peer, reason: DisconnectionReasonList) =
    trace "disconnect message received", reason=reason.value, peer
    await peer.disconnect(reason.value, false)

  # Adding an empty RLP list as the spec defines.
  # The parity client specifically checks if there is rlp data.
  proc ping(peer: Peer, emptyList: EmptyList) =
    discard peer.pong(EmptyList())

  proc pong(peer: Peer, emptyList: EmptyList) =
    discard

proc removePeer(network: EthereumNode, peer: Peer) =
  # It is necessary to check if peer.remote still exists. The connection might
  # have been dropped already from the peers side.
  # E.g. when receiving a p2p.disconnect message from a peer, a race will happen
  # between which side disconnects first.
  if network.peerPool != nil and not peer.remote.isNil and
      peer.remote in network.peerPool.connectedNodes:
    network.peerPool.connectedNodes.del(peer.remote)
    rlpx_connected_peers.dec()

    # Note: we need to do this check as disconnect (and thus removePeer)
    # currently can get called before the dispatcher is initialized.
    if not peer.dispatcher.isNil:
      for observer in network.peerPool.observers.values:
        if not observer.onPeerDisconnected.isNil:
          if observer.protocol.isNil or peer.supports(observer.protocol):
            observer.onPeerDisconnected(peer)

proc callDisconnectHandlers(peer: Peer, reason: DisconnectionReason):
    Future[void] {.async.} =
  var futures = newSeqOfCap[Future[void]](allProtocols.len)

  for protocol in peer.dispatcher.activeProtocols:
    if protocol.disconnectHandler != nil:
      futures.add((protocol.disconnectHandler)(peer, reason))

  await allFutures(futures)

  for f in futures:
    doAssert(f.finished())
    if f.failed():
      trace "Disconnection handler ended with an error", err = f.error.msg

proc disconnect*(peer: Peer, reason: DisconnectionReason,
    notifyOtherPeer = false) {.async.} =
  if peer.connectionState notin {Disconnecting, Disconnected}:
    peer.connectionState = Disconnecting
    # Do this first so sub-protocols have time to clean up and stop sending
    # before this node closes transport to remote peer
    if not peer.dispatcher.isNil:
      # In case of `CatchableError` in any of the handlers, this will be logged.
      # Other handlers will still execute.
      # In case of `Defect` in any of the handlers, program will quit.
      await callDisconnectHandlers(peer, reason)

    if notifyOtherPeer and not peer.transport.closed:
      var fut = peer.sendDisconnectMsg(DisconnectionReasonList(value: reason))
      yield fut
      if fut.failed:
        debug "Failed to deliver disconnect message", peer

      proc waitAndClose(peer: Peer, time: Duration) {.async.} =
        await sleepAsync(time)
        await peer.transport.closeWait()

      # Give the peer a chance to disconnect
      traceAsyncErrors peer.waitAndClose(2.seconds)
    elif not peer.transport.closed:
      peer.transport.close()

    logDisconnectedPeer peer
    peer.connectionState = Disconnected
    removePeer(peer.network, peer)

func validatePubKeyInHello(msg: DevP2P.hello, pubKey: PublicKey): bool =
  let pk = PublicKey.fromRaw(msg.nodeId)
  pk.isOk and pk[] == pubKey

func checkUselessPeer(peer: Peer) {.raises: [UselessPeerError].} =
  if peer.dispatcher.numProtocols == 0:
    # XXX: Send disconnect + UselessPeer
    raise newException(UselessPeerError, "Useless peer")

proc initPeerState*(peer: Peer, capabilities: openArray[Capability])
    {.raises: [UselessPeerError].} =
  peer.dispatcher = getDispatcher(peer.network, capabilities)
  # checkUselessPeer(peer)
  info "initPeerState"
  # The dispatcher has determined our message ID sequence.
  # For each message ID, we allocate a potential slot for
  # tracking responses to requests.
  # (yes, some of the slots won't be used).
  peer.outstandingRequests.newSeq(peer.dispatcher.messages.len)
  for d in mitems(peer.outstandingRequests):
    d = initDeque[OutstandingRequest]()

  # Similarly, we need a bit of book-keeping data to keep track
  # of the potentially concurrent calls to `nextMsg`.
  peer.awaitedMessages.newSeq(peer.dispatcher.messages.len)
  peer.lastReqId = 0
  peer.initProtocolStates peer.dispatcher.activeProtocols
  info "initProtocolStates"

proc postHelloSteps(peer: Peer, h: DevP2P.hello) {.async.} =
  info "postHelloSteps", peer=peer, capabilities=h.capabilities
  initPeerState(peer, h.capabilities)

  # Please note that the ordering of operations here is important!
  #
  # We must first start all handshake procedures and give them a
  # chance to send any initial packages they might require over
  # the network and to yield on their `nextMsg` waits.
  #
  var subProtocolsHandshakes = newSeqOfCap[Future[void]](allProtocols.len)
  for protocol in peer.dispatcher.activeProtocols:
    if protocol.handshake != nil:
      subProtocolsHandshakes.add((protocol.handshake)(peer))

  # The handshake may involve multiple async steps, so we wait
  # here for all of them to finish.
  #
  await allFutures(subProtocolsHandshakes)

  for handshake in subProtocolsHandshakes:
    doAssert(handshake.finished())
    if handshake.failed():
      raise handshake.error

  # The `dispatchMessages` loop must be started after this.
  # Otherwise, we risk that some of the handshake packets sent by
  # the other peer may arrive too early and be processed before
  # the handshake code got a change to wait for them.
  #
  var messageProcessingLoop = peer.dispatchMessages()

  messageProcessingLoop.callback = proc(p: pointer) {.gcsafe.} =
    if messageProcessingLoop.failed:
      info "Ending dispatchMessages loop", peer,
            err = messageProcessingLoop.error.msg
      traceAsyncErrors peer.disconnect(ClientQuitting)

  # This is needed as a peer might have already disconnected. In this case
  # we need to raise so that rlpxConnect/rlpxAccept fails.
  # Disconnect is done only to run the disconnect handlers. TODO: improve this
  # also TODO: Should we discern the type of error?
  if messageProcessingLoop.finished:
    await peer.disconnectAndRaise(ClientQuitting,
                                  "messageProcessingLoop ended while connecting")
  peer.connectionState = Connected

template `^`(arr): auto =
  # passes a stack array with a matching `arrLen`
  # variable as an open array
  arr.toOpenArray(0, `arr Len` - 1)

proc initSecretState(p: Peer, hs: Handshake, authMsg, ackMsg: openArray[byte]) =
  var secrets = hs.getSecrets(authMsg, ackMsg)
  initSecretState(secrets, p.secretsState)
  burnMem(secrets)

template setSnappySupport(peer: Peer, node: EthereumNode, handshake: Handshake) =
  when useSnappy:
    peer.snappyEnabled = node.protocolVersion >= devp2pSnappyVersion.uint and
                         handshake.version >= devp2pSnappyVersion.uint

template getVersion(handshake: Handshake): uint =
  when useSnappy:
    handshake.version
  else:
    devp2pVersion

template baseProtocolVersion(node: EthereumNode): untyped =
  when useSnappy:
    node.protocolVersion
  else:
    devp2pVersion

template baseProtocolVersion(peer: Peer): uint =
  when useSnappy:
    if peer.snappyEnabled: devp2pSnappyVersion
    else: devp2pVersion
  else:
    devp2pVersion

type
  RlpxError* = enum
    TransportConnectError,
    RlpxHandshakeTransportError,
    RlpxHandshakeError,
    ProtocolError,
    P2PHandshakeError,
    P2PTransportError,
    InvalidIdentityError,
    UselessRlpxPeerError,
    PeerDisconnectedError,
    TooManyPeersError

proc rlpxConnect*(node: EthereumNode, remote: Node):
    Future[Result[Peer, RlpxError]] {.async.} =

  initTracing(devp2pInfo, node.protocols)

  let peer = Peer(remote: remote, network: node)
  let ta = initTAddress(remote.node.address.ip, remote.node.address.tcpPort)
  info "rlpxConnect",ta=ta
  var error = true
  defer:
    if error: 
      if not isNil(peer.transport):
        if not peer.transport.closed:
          peer.transport.close()

  peer.transport =
    try:
      await connect(ta)
    except TransportError:
      info "rlpxConnect", TransportError= getCurrentExceptionMsg()
      return err(TransportConnectError)
    except CatchableError as e:
      # Aside from TransportOsError, seems raw CatchableError can also occur?
      info "TCP connect with peer failed", err = $e.name, errMsg = $e.msg
      return err(TransportConnectError)

  # RLPx initial handshake
  var
    handshake = Handshake.init(
      node.rng[], node.keys, {Initiator, EIP8}, node.baseProtocolVersion)
    authMsg: array[AuthMessageMaxEIP8, byte]
    authMsgLen = 0
  # TODO: Rework this so we won't have to pass an array as parameter?
  authMessage(handshake, node.rng[], remote.node.pubkey, authMsg, authMsgLen).tryGet()

  info "rlpxConnect",authMsg=authMsgLen
  let writeRes =
    try:
      await peer.transport.write(addr authMsg[0], authMsgLen)
    except TransportError:
      info "rlpxConnect", TransportError= getCurrentExceptionMsg()
      return err(RlpxHandshakeTransportError)
    except CatchableError as e: # TODO: Only TransportErrors can occur?
      raiseAssert($e.name & " " & $e.msg)
  info "rlpxConnect", writeRes=writeRes, authMsgLen=authMsgLen
  if writeRes != authMsgLen:
    return err(RlpxHandshakeTransportError)

  var ackMsg = await peer.transport.read()
  info "ackMsg", ackMsg=ackMsg
  var size = uint16.fromBytesBE(ackMsg)
  info "fromBytesBE", size=size
  let res = handshake.decodeAckMessage(ackMsg)
  if res.isErr and res.error == AuthError.IncompleteError:
    info "decodeAckMessage", err=res.error
  # peer.setSnappySupport(node, handshake)
  peer.initSecretState(handshake, ^authMsg, ackMsg)

  logConnectedPeer peer

  # RLPx p2p capability handshake: After the initial handshake, both sides of
  # the connection must send either Hello or a Disconnect message.
  let sendHelloFut = peer.hello(
      handshake.getVersion(),
      node.clientId,
      node.capabilities,
      uint(node.address.tcpPort),
      node.keys.pubkey.toRaw())

  var receiveHelloFut = peer.waitSingleMsg(DevP2P.hello)
  info "receiveHelloFut"
  var response =
      try:
        await peer.handshakeImpl(
          sendHelloFut,
          receiveHelloFut,
          10.seconds)
      except RlpError:
        return err(ProtocolError)
      except PeerDisconnected as e:
        return err(PeerDisconnectedError)
      except TransportError:
        return err(P2PTransportError)
      except CatchableError as e:
        raiseAssert($e.name & " " & $e.msg)

  if not validatePubKeyInHello(response, remote.node.pubkey):
    warn "Wrong devp2p identity in Hello message"
    return err(InvalidIdentityError)

  info "DevP2P handshake completed", peer = remote, clientId = response.clientId

  try:
    info "postHelloSteps", response=response
    await postHelloSteps(peer, response)
  except RlpError:
    return err(ProtocolError)
  except PeerDisconnected as e:
    case e.reason:
    of TooManyPeers:
      return err(TooManyPeersError)
    else:
      return err(PeerDisconnectedError)
  except UselessPeerError:
    return err(UselessRlpxPeerError)
  except TransportError:
    return err(P2PTransportError)
  except CatchableError as e:
    raiseAssert($e.name & " " & $e.msg)

  info "Peer fully connected", peer = remote, clientId = response.clientId

  return ok(peer)

# TODO: rework rlpxAccept similar to rlpxConnect.
proc rlpxAccept*(
    node: EthereumNode, transport: StreamTransport): Future[Peer] {.async.} =
  initTracing(devp2pInfo, node.protocols)
  let peer = Peer(transport: transport, network: node)
  info "rlpxAccept", peer=peer.transport.remoteAddress
  var handshake = Handshake.init(node.rng[], node.keys, {auth.Responder})
  var ok = false
  try:
    var prefixSize:uint16 = 0
    # var m:array[2, byte]
    await transport.readExactly(cast[ptr array[2,byte]](addr prefixSize), sizeof(prefixSize))
    # prefixSize = uint16.fromBytesBE(m)
    info "rlpxAccept", prefixSize=prefixSize
    var authMsg = newSeq[byte](prefixSize)

    await transport.readExactly(addr authMsg[0], int prefixSize)
    var ret = handshake.decodeAuthMessage(authMsg)
    if ret.isErr and ret.error == AuthError.IncompleteError:
      info "rlpxAccept", ret=ret.error
      await transport.readExactly(addr authMsg[prefixSize-1], len(authMsg) - prefixSize.int)
      ret = handshake.decodeAuthMessage(authMsg)


    if ret.isErr():
      # It is likely that errors on the handshake Auth is just garbage arriving
      # on the TCP port as it is the first data on the incoming connection,
      # hence log them as trace.
      info "rlpxAccept handshake error", error = ret.error
      if not isNil(peer.transport):
        peer.transport.close()

      rlpx_accept_failure.inc()
      rlpx_accept_failure.inc(labelValues = ["handshake_error"])
      return nil

    ret.get()

    peer.setSnappySupport(node, handshake)
    handshake.version = uint8(peer.baseProtocolVersion)

    var ackMsg: array[AckMessageMaxEIP8, byte]
    var ackMsgLen: int
    handshake.ackMessage(node.rng[], ackMsg, ackMsgLen).tryGet()
    var res = await transport.write(addr ackMsg[0], ackMsgLen)
    if res != ackMsgLen:
      raisePeerDisconnected("Unexpected disconnect while authenticating",
                            TcpError)

    peer.initSecretState(handshake, authMsg, ^ackMsg)

    let listenPort = transport.localAddress().port

    logAcceptedPeer peer

    var sendHelloFut = peer.hello(
      peer.baseProtocolVersion,
      node.clientId,
      node.capabilities,
      listenPort.uint,
      node.keys.pubkey.toRaw())

    var response = await peer.handshakeImpl(
      sendHelloFut,
      peer.waitSingleMsg(DevP2P.hello),
      10.seconds)

    info "Received Hello", version=response.version, id=response.clientId

    if not validatePubKeyInHello(response, handshake.remoteHPubkey):
      warn "A Remote nodeId is not its public key" # XXX: Do we care?

    let remote = transport.remoteAddress()
    let address = Address(ip: remote.address, tcpPort: remote.port,
                          udpPort: remote.port)
    peer.remote = newNode(
      ENode(pubkey: handshake.remoteHPubkey, address: address))

    info "devp2p handshake completed", peer = peer.transport.remoteAddress,
      clientId = response.clientId

    if peer.remote in node.peerPool.connectedNodes or
        peer.remote in node.peerPool.connectingNodes:
      info "Duplicate connection in rlpxAccept"
      raisePeerDisconnected("Peer already connecting or connected",
                            AlreadyConnected)

    node.peerPool.connectingNodes.incl(peer.remote)

    await postHelloSteps(peer, response)
    ok = true
    info "Peer fully connected", peer = peer.transport.remoteAddress, clientId = response.clientId
  except PeerDisconnected as e:
    case e.reason
      of AlreadyConnected, TooManyPeers, MessageTimeout:
        info "Disconnect during rlpxAccept", reason = e.reason, peer = peer.transport.remoteAddress
      else:
        info "Unexpected disconnect during rlpxAccept", reason = e.reason, msg = e.msg, peer = peer.transport.remoteAddress

    rlpx_accept_failure.inc(labelValues = [$e.reason])
  except TransportIncompleteError:
    info "Connection dropped in rlpxAccept", remote = peer.remote
    rlpx_accept_failure.inc(labelValues = [$TransportIncompleteError])
  except UselessPeerError:
    info "Disconnecting useless peer", peer = peer.transport.remoteAddress
    rlpx_accept_failure.inc(labelValues = [$UselessPeerError])
  except RlpTypeMismatch as e:
    # Some peers report capabilities with names longer than 3 chars. We ignore
    # those for now. Maybe we should allow this though.
    info "Rlp error in rlpxAccept", err = e.msg, errName = e.name
    rlpx_accept_failure.inc(labelValues = [$RlpTypeMismatch])
  except TransportOsError as e:
    info "TransportOsError", err = e.msg, errName = e.name
    if e.code == OSErrorCode(110):
      rlpx_accept_failure.inc(labelValues = ["tcp_timeout"])
    else:
      rlpx_accept_failure.inc(labelValues = [$e.name])
  except CatchableError as e:
    error "Unexpected exception in rlpxAccept", exc = e.name, err = e.msg
    rlpx_accept_failure.inc(labelValues = [$e.name])

  if not ok:
    if not isNil(peer.transport):
      peer.transport.close()

    rlpx_accept_failure.inc()
    return nil
  else:
    rlpx_accept_success.inc()
    return peer

when isMainModule:

  when false:
    # The assignments below can be used to investigate if the RLPx procs
    # are considered GcSafe. The short answer is that they aren't, because
    # they dispatch into user code that might use the GC.
    type
      GcSafeDispatchMsg = proc (peer: Peer, msgId: int, msgData: var Rlp)

      GcSafeRecvMsg = proc (peer: Peer):
        Future[tuple[msgId: int, msgData: Rlp]] {.gcsafe.}

      GcSafeAccept = proc (transport: StreamTransport, myKeys: KeyPair):
        Future[Peer] {.gcsafe.}

    var
      dispatchMsgPtr = invokeThunk
      recvMsgPtr: GcSafeRecvMsg = recvMsg
      acceptPtr: GcSafeAccept = rlpxAccept
