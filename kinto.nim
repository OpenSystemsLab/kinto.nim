import httpclient, strutils, uri, base64, logging, typetraits, macros, ../sam.nim/sam
import private/util

type
  KintoException* = object of Exception
    ## Errors returned by server
    response*: Response
      ## responsed packet

  BucketNotFoundException* = KintoException
    ## Bucket not found or not accessible

  KintoClient = object of RootObj
    remote: string
    headers: string
    bucket: string
    collection: string
    proxy: Proxy

  KintoObject = object of RootObj
    id*: string
    last_modified*: int
    permissions*: Permissions

  Permissions = object of RootObj
    read*: seq[string]
    write*: seq[string]
    create*: seq[string]

  Bucket* = object of KintoObject
    ## Kinto bucket instance
  Collection* = object of KintoObject
    ## Kinto collection instance
  Model* = object of KintoObject
    ## Kinto record instance
  Group* = object of KintoObject
    ## Kinto group instance


const
  USER_AGENT = "kinto.nim/0.0.1"
  DO_NOT_OVERWRITE = "If-None-Match: \"*\"\c\L"

  BATCH_ENDPOINT =        "/batch"
  BUCKETS_ENDPOINT =      "/buckets"
  BUCKET_ENDPOINT =       "/buckets/$#"
  COLLECTION_ENDPOINT =   "/buckets/$#/collections/$#"
  RECORDS_ENDPOINT =      "/buckets/$#/collections/$#/records"
  RECORD_ENDPOINT =       "/buckets/$#/collections/$#/records/$#"
  GROUPS_ENDPOINT =       "/buckets/$#/groups"
  GROUP_ENDPOINT =        "/buckets/$#/groups/$#"


when defined(debug):
  let L = newConsoleLogger()
  addHandler(L)

proc id*(k: KintoObject): string {.inline.} =
  ## Getter of Object ID
  k.id

proc lastModified*(k: KintoObject): int {.inline.} =
  ## Getter of last modified
  k.lastModified

proc newPermissions(node: JsonNode = nil): Permissions =
  ## Create new permissions object
  result.read = @[]
  result.write = @[]
  result.create = @[]

  if node != nil:
    if node.hasKey("read"):
      for perm in node["read"].items:
        result.read.add(perm.toStr)

    if node.hasKey("write"):
      for perm in node["write"].items:
        result.write.add(perm.toStr)

    if node.hasKey("create"):
      for perm in node["create"].items:
        result.create.add(perm.toStr)

proc toJson[T: KintoObject](self: T): string =
  result = newStringOfCap(sizeof(self) shl 1)
  result.add "{\"data\":{"
  var i: int
  for name, value in self.fieldPairs:
    when not (name in @["last_modified", "deleted", "permissions"]):
      inc(i)
  for name, value in self.fieldPairs:
    when not (name in @["last_modified", "deleted", "permissions"]):
      dec(i)
      result.add "\"" & name & "\":"
      result.add value.dumps()
      if i > 0:
        result.add ","
  result.add "}}"

proc Kinto*(remote: string, username, password = "", bucket = "default", collection = "", proxy: tuple[url: string, auth: string]): KintoClient =
  ## Create new Kinto API client with proxy configurated
  result.remote = strip(remote, leading = false, chars={'/'})
  result.headers = "Content-Type: application/json\c\LAccept: application/json\c\L"
  if username != "":
    result.headers.add("Authorization: basic " & encode(username & ":" & password) & "\c\L")

  result.bucket = bucket
  result.collection = collection

  if proxy[0] != "":
    result.proxy = newProxy(proxy[0], proxy[1])

template Kinto*(remote: string, username, password = "", bucket = "default", collection = "", proxy: string): expr =
  ## Create new Kinto API client with proxy that not requires authentication
  Kinto(remote, username, password, bucket, collection, (proxy, ""))

template Kinto*(remote: string, username, password = "", bucket = "default", collection = ""): expr =
  ## Create new Kinto API client
  Kinto(remote, username, password, bucket, collection, ("", ""))


proc getEndpoint(self: KintoClient, kind: string, a, b, c = ""): string {.inline, noSideEffect.} =
  kind % [a or self.bucket, b or self.collection, c]

proc request(self: KintoClient, httpMethod, endpoint: string, data, perms = "", headers = ""): JsonNode =
  let parsed = parseUri(endpoint)
  var actualUrl: string
  if parsed.scheme == "":
    actualUrl = self.remote & endpoint
  else:
    actualUrl = endpoint

  var extraHeaders = ""
  extraHeaders.add(self.headers)
  if headers != nil:
    extraHeaders.add(headers)

  let payload = if data.isNil: "" else: $data
  extraHeaders.add("Content-Length: " & $len(payload) & "\c\L")

  debug("-------------------------------------")
  debug(httpMethod, " ", actualUrl)
  debug(extraHeaders)
  debug(payload)

  let response = request(actualUrl,
                         httpMethod,
                         extraHeaders,
                         payload,
                         userAgent=USER_AGENT,
                         proxy=self.proxy)

  debug("Status: ", response.status)
  debug("Body: ", response.body)

  result = parse(response.body)
  let status = response.getStatusCode()

  if status < 200 or status >= 400:
    let error = newException(KintoException, $status & " - " & result["message"].toStr)
    error.response = response
    raise error

proc getCacheHeaders(self: KintoObject, safe: bool, lastModified = 0): string =
  result = ""
  if safe:
    var lastModified = lastModified
    if lastModified == 0 and self.lastModified > 0:
      lastModified = self.lastModified
    if lastModified != 0:
      result = "If-Match: \"" & $lastModified & "\"\c\L"

proc use*(self: var KintoClient, bucket: string) =
  ## Switch to other bucket
  if bucket.isNil:
    raise newException(ValueError, "Bucket name is required")
  self.bucket = bucket

proc collection*(self: KintoClient, collection: string): KintoClient =
  ## Return a Kinto Client with new collection
  if collection.isNil or collection == "":
    raise newException(ValueError, "Collection name is required")

  result.remote = self.remote
  result.bucket = self.bucket
  result.collection = collection
  result.proxy = self.proxy

#----------------------------
# Buckets
#----------------------------
proc getBuckets*(self: KintoClient): seq[Bucket] =
  ## Returns the list of accessible buckets
  result = @[]
  var body = self.request($httpGET, self.getEndpoint(BUCKETS_ENDPOINT))
  for node in body["data"].items:
    var b: Bucket
    b.id = node["id"].toStr
    b.lastModified = node["last_modified"].toInt

    result.add(b)

proc getBucket*(self: KintoClient, id: string): Bucket =
  ## Returns a specific bucket by its ID
  if id.isNil or id == "":
    raise newException(ValueError, "Bucket name is empty")
  try:
    var body = self.request($httpGET, self.getEndpoint(BUCKET_ENDPOINT, id))

    result.id = body["data"]["id"].toStr
    result.lastModified = body["data"]["last_modified"].toInt
    result.permissions = toObj[Permissions](body["permissions"])
  except KintoException:
    raise newException(BucketNotFoundException, "Bucket not found or not accessible: " & id)

proc createBucket*(self: KintoClient, id = ""): Bucket =
  ## Creates a new bucket
  ## If id is not provided, it is automatically generated.

  if id != "":
    result.id = id

  var body = self.request("httpPOST", self.getEndpoint(BUCKETS_ENDPOINT), result.dumps)

  result.lastModified = body["data"]["last_modified"].toInt
  if body.hasKey("permission"):
    result.permissions = toObj[Permissions](body["permissions"])

proc save*(self: KintoClient, bucket: var Bucket, safe = true, forceOverwrite = false) =
  ## Creates or replaces a bucket with a specific ID
  var headers = ""
  if not forceOverwrite:
    headers.add(DO_NOT_OVERWRITE)

  headers.add(bucket.getCacheHeaders(safe))

  var body = self.request("httpPUT", self.getEndpoint(BUCKET_ENDPOINT, bucket.id), bucket.dumps, headers=headers)
  bucket.lastModified = body["data"]["last_modified"].toInt
  bucket.permissions = toObj[Permissions](body["permissions"])

proc drop*(self: KintoClient, bucket: Bucket, safe = true, lastModified = 0) =
  let headers = bucket.getCacheHeaders(safe, lastModified=lastModified)
  discard self.request($httpDELETE, self.getEndpoint(BUCKET_ENDPOINT, bucket.id), headers=headers)

#----------------------------
# Collections
#----------------------------
proc getCollections*(self: KintoClient): seq[Collection] =
  ## Returns the list of accessible buckets
  result = @[]
  var
    body = self.request($httpGET, self.getEndpoint(BUCKETS_ENDPOINT))
    c: Collection
  for n in body["data"].items:
    c = toObj[Collection](n)
    result.add(c)

proc get*[T: Collection](self: KintoClient, _: typedesc[T]): T =
  try:
    var body = self.request($httpGET, self.getEndpoint(COLLECTION_ENDPOINT, self.bucket, name(T).toLower))

    result = toObj[T](body["data"])
    result.permissions = toObj[Permissions](body["permissions"])
  except KintoException:
    raise

proc save*[T: Collection](self: KintoClient, obj: var T, safe = true, forceOverwrite = false) =
  var
    headers = ""
    body: JsonNode

  if not forceOverwrite:
    headers.add(DO_NOT_OVERWRITE)

  if obj.id == nil:
    obj.id = toLower(name(T))
  else:
    headers.add(obj.getCacheHeaders(safe))
  body = self.request($httpPUT, self.getEndpoint(COLLECTION_ENDPOINT, self.bucket, name(T).toLower), toJson(obj), headers=headers)

  obj.lastModified = body["data"]["last_modified"].toInt
  obj.permissions = toObj[Permissions](body{}["permissions"])

proc drop*[T: Collection](self: KintoClient, collection: T, safe = true, lastModified = 0) =
  let headers = collection.getCacheHeaders(safe, lastModified=lastModified)
  discard self.request($httpDELETE, self.getEndpoint(COLLECTION_ENDPOINT, self.bucket, name(T).toLower), headers=headers)

discard """
proc getRecord*(self: KintoObject, record: string, collection, bucket = ""): JsonNode =
  var body = self.request($httpGET, self.getEndpoint(RECORD_ENDPOINT, bucket or self.bucket, collection or self.collection, record))
  result = body

proc createRecord*(self: KintoObject, data: JsonNode, collection, bucket = "", permissions: JsonNode = nil): JsonNode =
  var body = self.request($httpPOST, self.getEndpoint(RECORDS_ENDPOINT, bucket or self.bucket, collection or self.collection), data=data, permissions=permissions)
  result = body

proc updateRecord*(self: KintoObject, record: string, data: JsonNode = nil, collection, bucket = "", permissions: JsonNode = nil, safe = true, ifNotExists = false, lastModified = 0): JsonNode =
  if ifNotExists:
    try:
      return self.createRecord(data, collection, bucket, permissions=permissions)
    except KintoException:
      let e = (ref KintoException)(getCurrentException())
      if e.response.getStatusCode() != 412:
        raise e
      result = self.getRecord(record, collection, bucket)
      return

  var headers =
    if safe:
      DO_NOT_OVERWRITE
    else:
      ""
  headers.add(self.getCacheHeaders(safe, data, lastModified))

  var body = self.request($httpPUT, self.getEndpoint(RECORD_ENDPOINT, bucket or self.bucket, collection or self.collection, record), data=data, permissions=permissions, headers=headers)
  result = body

proc patchRecord*(self: KintoObject, record: string, data: JsonNode = nil, collection, bucket = "", permissions: JsonNode = nil): JsonNode =
  var(body, _) = self.request("httpPATCH", self.getEndpoint(RECORD_ENDPOINT, bucket or self.bucket, collection or self.collection, record), data=data, permissions=permissions)
  result = body

proc deleteRecord*(self: KintoObject, record: string, collection, bucket = "", safe = true, lastModified = 0): JsonNode =
  let headers = self.getCacheHeaders(safe, lastModified=lastModified)
  var body = self.request($httpDELETE, self.getEndpoint(RECORD_ENDPOINT, bucket or self.bucket, collection or self.collection, record), headers=headers)
  result = body

proc deleteRecords*(self: KintoObject, record: string, collection, bucket = ""): JsonNode =
  var body = self.request($httpDELETE, self.getEndpoint(RECORD_ENDPOINT, bucket or self.bucket, collection or self.collection, record))
  result = body

proc getRecords*(self: KintoObject, collection, bucket = ""): JsonNode =
  var body = self.request($httpGET, self.getEndpoint(RECORDS_ENDPOINT, bucket or self.bucket, collection or self.collection))
  result = body

proc getGroup*(self: KintoObject, group: string, bucket = ""): JsonNode =
  var body = self.request($httpGET, self.getEndpoint(GROUP_ENDPOINT, bucket or self.bucket, group))
  result = body

proc createGroup*(self: KintoObject, data: JsonNode, bucket = ""): JsonNode =
  var body = self.request($httpPOST, self.getEndpoint(GROUPS_ENDPOINT, bucket or self.bucket), data=data)
  result = body

proc updateGroup*(self: KintoObject, group: string, data: JsonNode, bucket = "", permissions: JsonNode = nil, safe = true, ifNotExists = false, lastModified = 0): JsonNode =
  if ifNotExists:
    try:
#      return self.createGroup(group, bucket)
      discard
    except KintoException:
      let e = (ref KintoException)(getCurrentException())
      if e.response.getStatusCode() != 412:
        raise e
      result = self.getGroup(group, bucket)
      return

  var headers =
    if safe:
      DO_NOT_OVERWRITE
    else:
      ""
  headers.add(self.getCacheHeaders(safe, data, lastModified))

  var body = self.request($httpPUT, self.getEndpoint(GROUP_ENDPOINT, bucket or self.bucket, group), data=data, permissions=permissions, headers=headers)
  result = body

proc deleteGroup*(self: KintoObject, group: string, bucket = "", safe = true, lastModified = 0): JsonNode =
  var body = self.request($httpDELETE, self.getEndpoint(GROUP_ENDPOINT, bucket or self.bucket, group))
  result = body

proc getGroups*(self: KintoObject, bucket = ""): JsonNode =
  var body = self.request($httpGET, self.getEndpoint(GROUPS_ENDPOINT, bucket or self.bucket))
  result = body
"""
