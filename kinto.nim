import httpclient, strtabs, strutils, json, uri, base64, logging
import private/util

type
  KintoException* = object of Exception
    response*: Response

  BucketNotFoundException* = KintoException

  KintoClient = ref object
    remote: string
    headers: string
    bucket: string
    collection: string
    proxy: Proxy

  Permissions* = ref object of RootObj
    read*: seq[string]
    write*: seq[string]
    create*: seq[string]

  KintoBase* = object of RootObj
    id*: string
    lastModified*: int
    permissions*: Permissions

  Bucket* = ref object of KintoBase
  Collection* = ref object of KintoBase
  Record* = ref object of KintoBase
  Group* = ref object of KintoBase


const
  USER_AGENT = "kinto.nim/0.0.1"
  DO_NOT_OVERWRITE = "If-None-Match: \"*\"\c\L"

  BATCH_ENDPOINT =        "/batch"
  BUCKETS_ENDPOINT =      "/buckets"
  BUCKET_ENDPOINT =       "/buckets/$#"
  COLLECTIONS_ENDPOINT =  "/buckets/$#/collections"
  COLLECTION_ENDPOINT =   "/buckets/$#/collections/$#"
  RECORDS_ENDPOINT =      "/buckets/$#/collections/$#/records"
  RECORD_ENDPOINT =       "/buckets/$#/collections/$#/records/$#"
  GROUPS_ENDPOINT =       "/buckets/$#/groups"
  GROUP_ENDPOINT =        "/buckets/$#/groups/$#"

proc `or`(a, b: string): string {.inline, noSideEffect.} =
  if a.isNil or a == "":
    b
  else:
    a

when defined(debug):
  let L = newConsoleLogger()
  addHandler(L)

proc newPermissions*(): Permissions =
  new(result)
  result.read = @[]
  result.write = @[]
  result.create = @[]

proc newPermissions(node: JsonNode): Permissions =
  result = newPermissions()

  if node.hasKey("read"):
    for perm in node["read"].items:
      result.read.add(perm.str)

  if node.hasKey("write"):
    for perm in node["write"].items:
      result.write.add(perm.str)

  if node.hasKey("create"):
    for perm in node["create"].items:
      result.create.add(perm.str)

proc toJson(perms: Permissions): JsonNode {.inline.} =
  result = newJObject()
  if perms.read.len > 0:
    var readPerms = newJArray()
    for p in perms.read:
      readPerms.add(newJString(p))
    result.add("read", readPerms)

  if perms.write.len > 0:
    var writePerms = newJArray()
    for p in perms.write:
      writePerms.add(newJString(p))
    result.add("write", writePerms)

  if perms.create.len > 0:
    var createPerms = newJArray()
    for p in perms.read:
      createPerms.add(newJString(p))
    result.add("create", createPerms)


proc newKintoClient*(remote: string, username, password = "", bucket = "default", collection = "", proxy: tuple[url: string, auth: string]): KintoClient =
  ## Create new Kinto API client with proxy configurated
  new(result)

  result.remote = strip(remote, leading = false, chars={'/'})
  result.headers = "Content-Type: application/json\c\LAccept: application/json\c\L"
  if username != "":
    result.headers.add("Authorization: Basic " & encode(username & ":" & password) & "\c\L")

  result.bucket = bucket
  result.collection = collection

  if proxy[0] != "":
    result.proxy = newProxy(proxy[0], proxy[1])

proc getEndpoint(self: KintoClient, kind: string, a, b, c = ""): string {.inline, noSideEffect.} =
  kind % [
    a or self.bucket,
    b or self.collection,
    c
  ]

proc request(self: KintoClient, httpMethod, endpoint: string, data: JsonNode = nil, perms: Permissions = nil, headers = ""): tuple[body: JsonNode, headers: StringTableRef] =
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

  var payload = newJObject()

  if not data.isNil:
      payload.fields.add((key: "data", val: data))

  if not perms.isNil:
    payload.fields.add((key: "permissions", val: perms.toJson()))

  var tmp: string
  if payload.len > 0:
    tmp = $payload
    extraHeaders.add("Content-Length: " & $len(tmp) & "\c\L")
  else:
    tmp = ""

  debug("Remote: ", actualUrl)
  debug("Header: ", extraHeaders)
  debug("Payload: ", tmp)

  let response = request(actualUrl,
                         httpMethod,
                         extraHeaders,
                         tmp,
                         userAgent=USER_AGENT,
                         proxy=self.proxy)

  debug("Status: ", response.status)
  debug("Body: ", response.body)

  let body = parseJson(response.body)
  let status = response.getStatusCode()

  if status < 200 or status >= 400:
    let error = newException(KintoException, $status & " - " & body["message"].str)
    error.response = response
    raise error

  if status == 304:
    result = (newJNull(), response.headers)
  else:
    result = (body, response.headers)

proc getCacheHeaders(self: KintoClient, safe: bool, data: JsonNode = nil, lastModified = 0): string =
  result = ""
  var lastModified = lastModified
  if lastModified == 0 and (not data.isNil and data.hasKey("last_modified")):
    lastModified = getNum(data["last_modified"]).int
  if safe and lastModified != 0:
    result = "If-Match: \"" & $lastModified & "\"\c\L"

proc newKintoClient*(remote: string, username, password = "", bucket = "default", collection = "", proxy: string): KintoClient =
  ## Create new Kinto API client with proxy not requires authentication
  newKintoClient(remote, username, password, bucket, collection, (proxy, ""))

proc newKintoClient*(remote: string, username, password = "", bucket = "default", collection = ""): KintoClient =
  ## Create new Kinto API client
  newKintoClient(remote, username, password, bucket, collection, ("", ""))

proc newBucket*(id: string, lastModified: int): Bucket =
  new(result)
  result.id = id
  result.lastModified = lastModified

proc use*(client: KintoClient, bucket: string) =
  ## Change the default database for current client
  if bucket.isNil:
    raise newException(ValueError, "Bucket name is required")
  client.bucket = bucket

proc getBuckets*(self: KintoClient): seq[Bucket] =
  ## Returns the list of accessible buckets
  result = @[]
  var (body, _) = self.request($httpGET, self.getEndpoint(BUCKETS_ENDPOINT))
  for node in body["data"].items:
    result.add(newBucket(node["id"].str, node["last_modified"].num.int))

proc getBucket*(self: KintoClient, id: string): Bucket =
  ## Returns a specific bucket by its ID
  try:
    var (body, _) = self.request($httpGET, self.getEndpoint(BUCKET_ENDPOINT, id))
    result = newBucket(body["data"]["id"].str, body["data"]["last_modified"].num.int)
    result.permissions = newPermissions(body["permissions"])
  except KintoException:
    raise newException(BucketNotFoundException, "Bucket not found or not accessible: " & id)

proc createBucket*(self: KintoClient, bucket = "", perms: Permissions = nil): Bucket =
  ## Creates a new bucket. If id is not provided, it is automatically generated.
  var data: JsonNode
  if bucket != "":
    data = %*{"id": bucket}

  var (body, _) = self.request("httpPOST", self.getEndpoint(BUCKETS_ENDPOINT), data=data, perms=perms)
  result = newBucket(body["data"]["id"].str, body["data"]["last_modified"].num.int)
  result.permissions = newPermissions(body["permissions"])

proc updateBucket*(self: KintoClient, permissions: JsonNode = nil, safe = true, ifNotExists = false, lastModified = 0): JsonNode =
  var headers = ""
  if ifNotExists:
    headers.add(DO_NOT_OVERWRITE)

  headers.add(self.getCacheHeaders(safe, data, lastModified))

  var (body, _) = self.request("httpPUT", self.getEndpoint(BUCKET_ENDPOINT, bucket), permissions=permissions, headers=headers)
  result = body

proc deleteBucket*(self: KintoClient, bucket: string, safe = true, lastModified = 0): JsonNode =
  let headers = self.getCacheHeaders(safe, lastModified=lastModified)
  var (body, _) = self.request($httpDELETE, self.getEndpoint(BUCKET_ENDPOINT, bucket), headers=headers)
  result = body

discard """
proc getCollection*(self: KintoClient, collection, bucket = ""): JsonNode =
  var (body, _) = self.request($httpGET, self.getEndpoint(COLLECTION_ENDPOINT, bucket or self.bucket, collection))
  result = body

proc createCollection*(self: KintoClient, collection, bucket = ""): JsonNode =
  var data: JsonNode
  if collection != "":
    data = %*{"id": collection}

  var (body, _) = self.request($httpPOST, self.getEndpoint(COLLECTIONS_ENDPOINT, bucket or self.bucket), data=data)
  result = body

proc updateCollection*(self: KintoClient, collection: string, bucket = "", data, permissions: JsonNode = nil, safe = true, ifNotExists = false, lastModified = 0): JsonNode =
  if ifNotExists:
    try:
      return self.createCollection(collection, bucket)
    except KintoException:
      let e = (ref KintoException)(getCurrentException())
      if e.response.getStatusCode() != 412:
        raise e
      result = self.getCollection(collection, bucket)
      return

  var headers =
    if safe:
      DO_NOT_OVERWRITE
    else:
      ""
  headers.add(self.getCacheHeaders(safe, data, lastModified))

  var (body, _) = self.request($httpPUT, self.getEndpoint(COLLECTION_ENDPOINT, bucket or self.bucket, collection), data=data, permissions=permissions, headers=headers)
  result = body

proc patchCollection*(self: KintoClient, collection: string, bucket = "", data, permissions: JsonNode = nil): JsonNode =
  var(body, _) = self.request("httpPATCH", self.getEndpoint(COLLECTION_ENDPOINT, bucket or self.bucket, collection), data=data, permissions=permissions)
  result = body

proc deleteCollection*(self: KintoClient, collection: string, bucket = "", safe = true, lastModified = 0): JsonNode =
  let headers = self.getCacheHeaders(safe, lastModified=lastModified)
  var (body, _) = self.request($httpDELETE, self.getEndpoint(COLLECTION_ENDPOINT, bucket or self.bucket, collection), headers=headers)
  result = body["data"]

proc getCollections*(self: KintoClient, bucket = ""): JsonNode =
  var (body, _) = self.request($httpGET, self.getEndpoint(COLLECTIONS_ENDPOINT, bucket or self.bucket))
  result = body

proc getRecord*(self: KintoClient, record: string, collection, bucket = ""): JsonNode =
  var (body, _) = self.request($httpGET, self.getEndpoint(RECORD_ENDPOINT, bucket or self.bucket, collection or self.collection, record))
  result = body

proc createRecord*(self: KintoClient, data: JsonNode, collection, bucket = "", permissions: JsonNode = nil): JsonNode =
  var (body, _) = self.request($httpPOST, self.getEndpoint(RECORDS_ENDPOINT, bucket or self.bucket, collection or self.collection), data=data, permissions=permissions)
  result = body

proc updateRecord*(self: KintoClient, record: string, data: JsonNode = nil, collection, bucket = "", permissions: JsonNode = nil, safe = true, ifNotExists = false, lastModified = 0): JsonNode =
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

  var (body, _) = self.request($httpPUT, self.getEndpoint(RECORD_ENDPOINT, bucket or self.bucket, collection or self.collection, record), data=data, permissions=permissions, headers=headers)
  result = body

proc patchRecord*(self: KintoClient, record: string, data: JsonNode = nil, collection, bucket = "", permissions: JsonNode = nil): JsonNode =
  var(body, _) = self.request("httpPATCH", self.getEndpoint(RECORD_ENDPOINT, bucket or self.bucket, collection or self.collection, record), data=data, permissions=permissions)
  result = body

proc deleteRecord*(self: KintoClient, record: string, collection, bucket = "", safe = true, lastModified = 0): JsonNode =
  let headers = self.getCacheHeaders(safe, lastModified=lastModified)
  var (body, _) = self.request($httpDELETE, self.getEndpoint(RECORD_ENDPOINT, bucket or self.bucket, collection or self.collection, record), headers=headers)
  result = body

proc deleteRecords*(self: KintoClient, record: string, collection, bucket = ""): JsonNode =
  var (body, _) = self.request($httpDELETE, self.getEndpoint(RECORD_ENDPOINT, bucket or self.bucket, collection or self.collection, record))
  result = body

proc getRecords*(self: KintoClient, collection, bucket = ""): JsonNode =
  var (body, _) = self.request($httpGET, self.getEndpoint(RECORDS_ENDPOINT, bucket or self.bucket, collection or self.collection))
  result = body

proc getGroup*(self: KintoClient, group: string, bucket = ""): JsonNode =
  var (body, _) = self.request($httpGET, self.getEndpoint(GROUP_ENDPOINT, bucket or self.bucket, group))
  result = body

proc createGroup*(self: KintoClient, data: JsonNode, bucket = ""): JsonNode =
  var (body, _) = self.request($httpPOST, self.getEndpoint(GROUPS_ENDPOINT, bucket or self.bucket), data=data)
  result = body

proc updateGroup*(self: KintoClient, group: string, data: JsonNode, bucket = "", permissions: JsonNode = nil, safe = true, ifNotExists = false, lastModified = 0): JsonNode =
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

  var (body, _) = self.request($httpPUT, self.getEndpoint(GROUP_ENDPOINT, bucket or self.bucket, group), data=data, permissions=permissions, headers=headers)
  result = body

proc deleteGroup*(self: KintoClient, group: string, bucket = "", safe = true, lastModified = 0): JsonNode =
  var (body, _) = self.request($httpDELETE, self.getEndpoint(GROUP_ENDPOINT, bucket or self.bucket, group))
  result = body

proc getGroups*(self: KintoClient, bucket = ""): JsonNode =
  var (body, _) = self.request($httpGET, self.getEndpoint(GROUPS_ENDPOINT, bucket or self.bucket))
  result = body
"""
