import
  std/[tables, options],
  nimcrypto, stint, chronicles, stew/results, bearssl, stew/byteutils,
  eth/[rlp, keys], typesv1, node, enr, hkdf, sessions

export keys

{.push raises: [Defect].}

const
  version: uint16 = 1
  idNoncePrefix = "discovery-id-nonce"
  idSignatureText  = "discovery v5 identity proof"
  keyAgreementPrefix = "discovery v5 key agreement"
  protocolIdStr = "discv5"
  protocolId = toBytes(protocolIdStr)
  gcmNonceSize* = 12
  idNonceSize* = 16
  gcmTagSize* = 16
  ivSize* = 16
  staticHeaderSize = protocolId.len + 2 + 2 + 1 + gcmNonceSize
  authdataHeadSize = sizeof(NodeId) + 1 + 1
  whoareyouSize = ivSize + staticHeaderSize + idNonceSize + 8

type
  AESGCMNonce* = array[gcmNonceSize, byte]
  IdNonce* = array[idNonceSize, byte]

  WhoareyouData* = object
    requestNonce*: AESGCMNonce
    idNonce*: IdNonce # TODO: This data is also available in challengeData
    recordSeq*: uint64
    challengeData*: seq[byte]

  Challenge* = object
    whoareyouData*: WhoareyouData
    pubkey*: Option[PublicKey]

  StaticHeader* = object
    flag: Flag
    nonce: AESGCMNonce
    authdataSize: uint16

  HandshakeSecrets* = object
    writeKey*: AesKey
    readKey*: AesKey

  Flag* = enum
    OrdinaryMessage = 0x00
    Whoareyou = 0x01
    HandshakeMessage = 0x02

  Packet* = object
    case flag*: Flag
    of OrdinaryMessage:
      messageOpt*: Option[Message]
      requestNonce*: AESGCMNonce
      srcId*: NodeId
    of Whoareyou:
      whoareyou*: WhoareyouData
    of HandshakeMessage:
      message*: Message # In a handshake we expect to always be able to decrypt
      # TODO record or node immediately?
      node*: Option[Node]
      srcIdHs*: NodeId

  Codec* = object
    localNode*: Node
    privKey*: PrivateKey
    handshakes*: Table[HandShakeKey, Challenge]
    sessions*: Sessions

  DecodeError* = enum
    HandshakeError = "discv5: handshake failed"
    PacketError = "discv5: invalid packet"
    DecryptError = "discv5: decryption failed"
    UnsupportedMessage = "discv5: unsupported message"

  DecodeResult*[T] = Result[T, DecodeError]
  EncodeResult*[T] = Result[T, cstring]

proc mapErrTo[T, E](r: Result[T, E], v: static DecodeError):
    DecodeResult[T] =
  r.mapErr(proc (e: E): DecodeError = v)

proc idNonceHash*(challengeData, ephkey: openarray[byte], nodeId: NodeId):
    MDigest[256] =
  var ctx: sha256
  ctx.init()
  ctx.update(idSignatureText)
  ctx.update(challengeData)
  ctx.update(ephkey)
  ctx.update(nodeId.toByteArrayBE())
  result = ctx.finish()
  ctx.clear()

proc signIDNonce*(privKey: PrivateKey, challengeData,
    ephKey: openarray[byte], nodeId: NodeId): SignatureNR =
  signNR(privKey, SkMessage(idNonceHash(challengeData, ephKey, nodeId).data))

proc deriveKeys*(n1, n2: NodeID, priv: PrivateKey, pub: PublicKey,
    challengeData: openarray[byte]): HandshakeSecrets =
  let eph = ecdhRawFull(priv, pub)

  var info = newSeqOfCap[byte](keyAgreementPrefix.len + 32 * 2)
  for i, c in keyAgreementPrefix: info.add(byte(c))
  info.add(n1.toByteArrayBE())
  info.add(n2.toByteArrayBE())

  var secrets: HandshakeSecrets
  static: assert(sizeof(secrets) == aesKeySize * 2)
  var res = cast[ptr UncheckedArray[byte]](addr secrets)

  hkdf(sha256, eph.data, challengeData, info,
    toOpenArray(res, 0, sizeof(secrets) - 1))
  secrets

proc encryptGCM*(key, nonce, pt, authData: openarray[byte]): seq[byte] =
  var ectx: GCM[aes128]
  ectx.init(key, nonce, authData)
  result = newSeq[byte](pt.len + gcmTagSize)
  ectx.encrypt(pt, result)
  ectx.getTag(result.toOpenArray(pt.len, result.high))
  ectx.clear()

proc decryptGCM*(key: AesKey, nonce, ct, authData: openarray[byte]):
    Option[seq[byte]] =
  if ct.len <= gcmTagSize:
    debug "cipher is missing tag", len = ct.len
    return

  var dctx: GCM[aes128]
  dctx.init(key, nonce, authData)
  var res = newSeq[byte](ct.len - gcmTagSize)
  var tag: array[gcmTagSize, byte]
  dctx.decrypt(ct.toOpenArray(0, ct.high - gcmTagSize), res)
  dctx.getTag(tag)
  dctx.clear()

  if tag != ct.toOpenArray(ct.len - gcmTagSize, ct.high):
    return

  return some(res)

proc encryptHeader*(id: NodeId, iv, header: openarray[byte]): seq[byte] =
  var ectx: CTR[aes128]
  ectx.init(id.toByteArrayBE().toOpenArray(0, 15), iv)
  result = newSeq[byte](header.len)
  ectx.encrypt(header, result)
  ectx.clear()

proc hasHandshake*(c: Codec, key: HandShakeKey): bool =
  c.handshakes.hasKey(key)

proc encodeStaticHeader*(flag: Flag, nonce: AESGCMNonce, authSize: int):
    seq[byte] =
  result.add(protocolId)
  result.add(version.toBytesBE())
  result.add(byte(flag))
  result.add(nonce)
  # TODO: assert on authSize of > 2^16?
  result.add((uint16(authSize)).toBytesBE())

proc encodeMessagePacket*(rng: var BrHmacDrbgContext, c: var Codec,
    toId: NodeID, toAddr: Address, message: openarray[byte]):
    (seq[byte], AESGCMNonce) =
  var nonce: AESGCMNonce
  brHmacDrbgGenerate(rng, nonce) # Random AESGCM nonce
  var iv: array[ivSize, byte]
  brHmacDrbgGenerate(rng, iv) # Random IV

  # static-header
  let authdata = c.localNode.id.toByteArrayBE()
  let staticHeader = encodeStaticHeader(Flag.OrdinaryMessage, nonce,
    authdata.len())
  # header = static-header || authdata
  var header: seq[byte]
  header.add(staticHeader)
  header.add(authdata)

  # message
  var messageEncrypted: seq[byte]
  var writeKey, readKey: AesKey
  if c.sessions.load(toId, toAddr, readKey, writeKey):
    messageEncrypted = encryptGCM(writeKey, nonce, message, @iv & header)
  else:
    # We might not have the node's keys if the handshake hasn't been performed
    # yet. That's fine, we send a random-packet and we will be responded with
    # a WHOAREYOU packet.
    # The 16 here is the aes gcm tag size, as an empty plain text would result
    # in that size. TODO: Is that ok though? Shouldn't some extra data be added
    # not to be recognized as a "random message"?
    var randomData: array[16, byte]
    brHmacDrbgGenerate(rng, randomData)
    messageEncrypted.add(randomData)

  let maskedHeader = encryptHeader(toId, iv, header)

  var packet: seq[byte]
  packet.add(iv)
  packet.add(maskedHeader)
  packet.add(messageEncrypted)

  return (packet, nonce)

proc encodeWhoareyouPacket*(rng: var BrHmacDrbgContext, c: var Codec,
    toId: NodeID, toAddr: Address, requestNonce: AESGCMNonce, recordSeq: uint64,
    pubkey: Option[PublicKey]): seq[byte] =
  var idNonce: IdNonce
  brHmacDrbgGenerate(rng, idNonce)

  # authdata
  var authdata: seq[byte]
  authdata.add(idNonce)
  authdata.add(recordSeq.tobytesBE)

  # static-header
  let staticHeader = encodeStaticHeader(Flag.Whoareyou, requestNonce,
    authdata.len())

  # header = static-header || authdata
  var header: seq[byte]
  header.add(staticHeader)
  header.add(authdata)

  var iv: array[ivSize, byte]
  brHmacDrbgGenerate(rng, iv) # Random IV

  let maskedHeader = encryptHeader(toId, iv, header)

  var packet: seq[byte]
  packet.add(iv)
  packet.add(maskedHeader)

  let
    whoareyouData = WhoareyouData(
      requestNonce: requestNonce,
      idNonce: idNonce,
      recordSeq: recordSeq,
      challengeData: @iv & header)
    challenge = Challenge(whoareyouData: whoareyouData, pubkey: pubkey)
    key = HandShakeKey(nodeId: toId, address: $toAddr)

  c.handshakes[key] = challenge

  return packet

proc encodeHandshakePacket*(rng: var BrHmacDrbgContext, c: var Codec,
    toId: NodeID, toAddr: Address, message: openarray[byte],
    whoareyouData: WhoareyouData, pubkey: PublicKey): seq[byte] =
  var header: seq[byte]
  var nonce: AESGCMNonce
  brHmacDrbgGenerate(rng, nonce)
  var iv: array[ivSize, byte]
  brHmacDrbgGenerate(rng, iv) # Random IV

  var authdata: seq[byte]
  var authdataHead: seq[byte]

  authdataHead.add(c.localNode.id.toByteArrayBE())
  authdataHead.add(64'u8) # sig-size: 64
  authdataHead.add(33'u8) # eph-key-size: 33
  authdata.add(authdataHead)

  let ephKeys = KeyPair.random(rng)
  let signature = signIDNonce(c.privKey, whoareyouData.challengeData,
    ephKeys.pubkey.toRawCompressed(), toId)

  authdata.add(signature.toRaw())
  # compressed pub key format (33 bytes)
  authdata.add(ephKeys.pubkey.toRawCompressed())

  # Add ENR of sequence number is newer
  if whoareyouData.recordSeq < c.localNode.record.seqNum:
    authdata.add(encode(c.localNode.record))

  let secrets = deriveKeys(c.localNode.id, toId, ephKeys.seckey, pubkey,
    whoareyouData.challengeData)

  # Header
  let staticHeader = encodeStaticHeader(Flag.HandshakeMessage, nonce,
    authdata.len())

  header.add(staticHeader)
  header.add(authdata)

  c.sessions.store(toId, toAddr, secrets.readKey, secrets.writeKey)
  let messageEncrypted = encryptGCM(secrets.writeKey, nonce, message, @iv & header)

  let maskedHeader = encryptHeader(toId, iv, header)

  var packet: seq[byte]
  packet.add(iv)
  packet.add(maskedHeader)
  packet.add(messageEncrypted)

  return packet

proc decodeHeader*(id: NodeId, iv, maskedHeader: openarray[byte]):
    DecodeResult[(StaticHeader, seq[byte])] =
  # No need to check staticHeader size as that is included in minimum packet
  # size check in decodePacket
  var ectx: CTR[aes128]
  ectx.init(id.toByteArrayBE().toOpenArray(0, ivSize - 1), iv)
  # Decrypt static-header part of the header
  var staticHeader = newSeq[byte](staticHeaderSize)
  ectx.decrypt(maskedHeader.toOpenArray(0, staticHeaderSize - 1), staticHeader)

  # Check fields of the static-header
  if staticHeader.toOpenArray(0, protocolId.len - 1) != protocolId:
    return err(PacketError)

  if uint16.fromBytesBE(staticHeader.toOpenArray(6, 7)) != version:
    return err(PacketError)

  if staticHeader[8] < Flag.low.byte or staticHeader[8] > Flag.high.byte:
    return err(PacketError)
  let flag = cast[Flag](staticHeader[8])

  var nonce: AESGCMNonce
  copyMem(addr nonce[0], unsafeAddr staticHeader[9], gcmNonceSize)

  let authdataSize = uint16.fromBytesBE(staticHeader.toOpenArray(21,
    staticHeader.high))

  # Input should have minimum size of staticHeader + provided authdata size
  # Can be larger as there can come a message after.
  if maskedHeader.len < staticHeaderSize + int(authdataSize):
    return err(PacketError)

  var authdata = newSeq[byte](int(authdataSize))
  ectx.decrypt(maskedHeader.toOpenArray(staticHeaderSize,
    staticHeaderSize + int(authdataSize) - 1), authdata)
  ectx.clear()

  ok((StaticHeader(authdataSize: authdataSize, flag: flag, nonce: nonce),
    staticHeader & authdata))

proc decodeMessage*(body: openarray[byte]): DecodeResult[Message] =
  ## Decodes to the specific `Message` type.
  if body.len < 1:
    return err(PacketError)

  if body[0] < MessageKind.low.byte or body[0] > MessageKind.high.byte:
    return err(PacketError)

  # This cast is covered by the above check (else we could get enum with invalid
  # data!). However, can't we do this in a cleaner way?
  let kind = cast[MessageKind](body[0])
  var message = Message(kind: kind)
  var rlp = rlpFromBytes(body.toOpenArray(1, body.high))
  if rlp.enterList:
    try:
      # TODO: 8 bytes limitation on RequestId decode.
      message.reqId = rlp.read(RequestId)
    except RlpError:
      return err(PacketError)

    proc decode[T](rlp: var Rlp, v: var T)
        {.inline, nimcall, raises:[RlpError, ValueError, Defect].} =
      for k, v in v.fieldPairs:
        v = rlp.read(typeof(v))

    try:
      case kind
      of unused: return err(PacketError)
      of ping: rlp.decode(message.ping)
      of pong: rlp.decode(message.pong)
      of findNode: rlp.decode(message.findNode)
      of nodes: rlp.decode(message.nodes)
      of talkreq: rlp.decode(message.talkreq)
      of talkresp: rlp.decode(message.talkresp)
      of regtopic, ticket, regconfirmation, topicquery:
        # We just pass the empty type of this message without attempting to
        # decode, so that the protocol knows what was received.
        # But we ignore the message as per specification as "the content and
        # semantics of this message are not final".
        discard
    except RlpError, ValueError:
      return err(PacketError)

    ok(message)
  else:
    err(PacketError)

proc decodeMessagePacket(c: var Codec, fromAddr: Address, nonce: AESGCMNonce,
    iv, header, ct: openArray[byte]): DecodeResult[Packet] =
  # We now know the exact size that the header should be
  if header.len != staticHeaderSize + sizeof(NodeId):
    return err(PacketError)

  let srcId = NodeId.fromBytesBE(header.toOpenArray(staticHeaderSize,
    header.high))

  var writeKey, readKey: AesKey
  if not c.sessions.load(srcId, fromAddr, readKey, writeKey):
    # Don't consider this an error, simply haven't done a handshake yet or
    # the session got removed.
    trace "Decrypting failed (no keys)"
    return ok(Packet(flag: Flag.OrdinaryMessage, requestNonce: nonce,
      srcId: srcId))

  let pt = decryptGCM(readKey, nonce, ct, @iv & @header)
  if pt.isNone():
    # Don't consider this an error, the session got probably removed at the
    # peer's side.
    trace "Decrypting failed (invalid keys)"
    c.sessions.del(srcId, fromAddr)
    return ok(Packet(flag: Flag.OrdinaryMessage, requestNonce: nonce,
      srcId: srcId))

  let message = ? decodeMessage(pt.get())

  return ok(Packet(flag: Flag.OrdinaryMessage,
    messageOpt: some(message), requestNonce: nonce, srcId: srcId))

proc decodeWhoareyouPacket(c: var Codec, nonce: AESGCMNonce,
    iv, header: openArray[byte]): DecodeResult[Packet] =
  # TODO improve this
  let authdata = header[staticHeaderSize..header.high()]
  # We now know the exact size that the authdata should be
  if authdata.len != idNonceSize + sizeof(uint64):
    return err(PacketError)

  var idNonce: IdNonce
  copyMem(addr idNonce[0], unsafeAddr authdata[0], idNonceSize)
  let whoareyou = WhoareyouData(requestNonce: nonce, idNonce: idNonce,
    recordSeq: uint64.fromBytesBE(
      authdata.toOpenArray(idNonceSize, authdata.high)),
    challengeData: @iv & @header)

  return ok(Packet(flag: Flag.Whoareyou, whoareyou: whoareyou))

proc decodeHandshakePacket(c: var Codec, fromAddr: Address, nonce: AESGCMNonce,
    iv, header, ct: openArray[byte]): DecodeResult[Packet] =
  # Checking if there is enough data to decode authdata-head
  if header.len <= staticHeaderSize + authdataHeadSize:
    return err(PacketError)

  let
    authdata = header[staticHeaderSize..header.high()]
    srcId = NodeId.fromBytesBE(authdata.toOpenArray(0, 31))
    sigSize = uint8(authdata[32])
    ephKeySize = uint8(authdata[33])

  # If smaller, as it can be equal and bigger (in case it holds an enr)
  if header.len < staticHeaderSize + authdataHeadSize + int(sigSize) + int(ephKeySize):
    return err(PacketError)

  let key = HandShakeKey(nodeId: srcId, address: $fromAddr)
  var challenge: Challenge
  if not c.handshakes.pop(key, challenge):
    debug "Decoding failed (no previous stored handshake challenge)"
    return err(HandshakeError)

  # This should be the compressed public key. But as we use the provided
  # ephKeySize, it should also work with full sized key. However, the idNonce
  # signature verification will fail.
  let
    ephKeyPos = authdataHeadSize + int(sigSize)
    ephKeyRaw = authdata[ephKeyPos..<ephKeyPos + int(ephKeySize)]
    ephKey = ? PublicKey.fromRaw(ephKeyRaw).mapErrTo(HandshakeError)

  var record: Option[enr.Record]
  let recordPos = ephKeyPos + int(ephKeySize)
  if authdata.len() > recordPos:
    # There is possibly an ENR still
    try:
      # Signature check of record happens in decode.
      record = some(rlp.decode(authdata.toOpenArray(recordPos, authdata.high),
        enr.Record))
    except RlpError, ValueError:
      return err(HandshakeError)

  var pubKey: PublicKey
  var newNode: Option[Node]
  # TODO: Shall we return Node or Record? Record makes more sense, but we do
  # need the pubkey and the nodeid
  if record.isSome():
    # Node returned might not have an address or not a valid address.
    let node = ? newNode(record.get()).mapErrTo(HandshakeError)
    if node.id != srcId:
      return err(HandshakeError)

    pubKey = node.pubKey
    newNode = some(node)
  else:
    if challenge.pubkey.isSome():
      pubKey = challenge.pubkey.get()
    else:
      # We should have received a Record in this case.
      return err(HandshakeError)

  # Verify the id-nonce-sig
  let sig = ? SignatureNR.fromRaw(
    authdata.toOpenArray(authdataHeadSize,
      authdataHeadSize + int(sigSize) - 1)).mapErrTo(HandshakeError)

  let h = idNonceHash(challenge.whoareyouData.challengeData, ephKeyRaw,
    c.localNode.id)
  if not verify(sig, SkMessage(h.data), pubkey):
    return err(HandshakeError)

  # Do the key derivation step only after id-nonce-sig is verified!
  var secrets = deriveKeys(srcId, c.localNode.id, c.privKey,
    ephKey, challenge.whoareyouData.challengeData)

  swap(secrets.readKey, secrets.writeKey)

  let pt = decryptGCM(secrets.readKey, nonce, ct, @iv & @header)
  if pt.isNone():
    c.sessions.del(srcId, fromAddr)
    # Differently from an ordinary message, this is seen as an error as the
    # secrets just got negotiated in the handshake.
    return err(DecryptError)

  let message = ? decodeMessage(pt.get())

  # Only store the session secrets in case decryption was successful and also
  # in case the message can get decoded.
  c.sessions.store(srcId, fromAddr, secrets.readKey, secrets.writeKey)

  return ok(Packet(flag: Flag.HandshakeMessage, message: message,
    srcIdHs: srcId, node: newNode))

proc decodePacket*(c: var Codec, fromAddr: Address, input: openArray[byte]):
    DecodeResult[Packet] =
  ## Decode a packet. This can be a regular packet or a packet in response to a
  ## WHOAREYOU packet. In case of the latter a `newNode` might be provided.
  # Smallest packet is Whoareyou packet so that is the minimum size
  if input.len() < whoareyouSize:
    return err(PacketError)

  # TODO: Just pass in the full input? Makes more sense perhaps..
  let (staticHeader, header) = ? decodeHeader(c.localNode.id,
    input.toOpenArray(0, ivSize - 1), # IV
    # Don't know the size yet of the full header, so we pass all.
    input.toOpenArray(ivSize, input.high))

  case staticHeader.flag
  of OrdinaryMessage:
    # TODO: Extra size check on ct data?
    return decodeMessagePacket(c, fromAddr, staticHeader.nonce,
      input.toOpenArray(0, ivSize - 1), header,
      input.toOpenArray(ivSize + header.len, input.high))

  of Whoareyou:
    # Header size got checked in decode header
    return decodeWhoareyouPacket(c, staticHeader.nonce,
      input.toOpenArray(0, ivSize - 1), header)

  of HandshakeMessage:
    # TODO: Extra size check on ct data?
    return decodeHandshakePacket(c, fromAddr, staticHeader.nonce,
      input.toOpenArray(0, ivSize - 1), header,
      input.toOpenArray(ivSize + header.len, input.high))

proc init*(T: type RequestId, rng: var BrHmacDrbgContext): T =
  var id = newSeq[byte](8) # RequestId must be <= 8 bytes
  brHmacDrbgGenerate(rng, id)
  id

proc numFields(T: typedesc): int =
  for k, v in fieldPairs(default(T)): inc result

proc encodeMessage*[T: SomeMessage](p: T, reqId: RequestId): seq[byte] =
  result = newSeqOfCap[byte](64)
  result.add(messageKind(T).ord)

  const sz = numFields(T)
  var writer = initRlpList(sz + 1)
  writer.append(reqId)
  for k, v in fieldPairs(p):
    writer.append(v)
  result.add(writer.finish())