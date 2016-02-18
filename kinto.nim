import httpclient, strtabs, strutils, json, uri, base64, logging
import private/util

type
  KintoException* = object of Exception
    response*: Response

  BucketNotFoundException* = KintoException

  KintoBase* = object of RootObj
    kintoConfigs: tuple[
      remote: string,
      headers: string,
      bucket: string,
      collection: string,
      proxy: Proxy
    ]
    id*: string
    last_modified*: int
    deleted*: bool
    permissions*: Permissions

  Permissions* = object of RootObj
    read*: seq[string]
    write*: seq[string]
    create*: seq[string]

  Bucket* = object of KintoBase
    ## Kinto bucket instance
  Collection* = object of KintoBase
    ## Kinto collection instance
  Model* = object of KintoBase
    ## Kinto record instance
  Group* = object of KintoBase
    #3 Kinto group instance


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


when defined(debug):
  let L = newConsoleLogger()
  addHandler(L)

proc newPermissions*(): Permissions =
  ## Create new empty permissions object
  result.read = @[]
  result.write = @[]
  result.create = @[]

proc newPermissions(node: JsonNode): Permissions =
  ## Create new permissions object from `JsonNode`
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

proc `%`(perms: Permissions): JsonNode =
  ## Serializes a permissions object to `JsonNode`
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

proc `%`(self: KintoBase): JsonNode =
  result = newJObject()
  var data = newJObject()
  var permissions: JsonNode
  for name, value in self.fieldPairs:
    when not (name in @["kintoConfigs", "last_modified", "deleted"]):
      when name == "permissions":
        permissions = %value
      else:
        if not value.isNil:
          data.fields.add((key: name, val: %value))

  if data.len > 0:
    result.fields.add((key: "data", val: data))
  if permissions.len > 0:
    result.fields.add((key: "permission", val: permissions))

proc Kinto*(remote: string, username, password = "", bucket = "default", collection = "", proxy: tuple[url: string, auth: string]): KintoBase =
  ## Create new Kinto API client with proxy configurated
  result.kintoConfigs.remote = strip(remote, leading = false, chars={'/'})
  result.kintoConfigs.headers = "Content-Type: application/json\c\LAccept: application/json\c\L"
  if username != "":
    result.kintoConfigs.headers.add("Authorization: basic " & encode(username & ":" & password) & "\c\L")

  result.kintoConfigs.bucket = bucket
  result.kintoConfigs.collection = collection

  if proxy[0] != "":
    result.kintoConfigs.proxy = newProxy(proxy[0], proxy[1])

template Kinto*(remote: string, username, password = "", bucket = "default", collection = "", proxy: string): expr =
  ## Create new Kinto API client with proxy that not requires authentication
  Kinto(remote, username, password, bucket, collection, (proxy, ""))

template Kinto*(remote: string, username, password = "", bucket = "default", collection = ""): expr =
  ## Create new Kinto API client
  Kinto(remote, username, password, bucket, collection, ("", ""))


proc getEndpoint(self: KintoBase, kind: string, a, b, c = ""): string {.inline, noSideEffect.} =
  kind % [a or self.kintoConfigs.bucket, b or self.kintoConfigs.collection, c]

proc request(self: KintoBase, httpMethod, endpoint: string, headers = ""): tuple[body: JsonNode, headers: StringTableRef] =
  let parsed = parseUri(endpoint)
  var actualUrl: string
  if parsed.scheme == "":
    actualUrl = self.kintoConfigs.remote & endpoint
  else:
    actualUrl = endpoint

  var extraHeaders = ""
  extraHeaders.add(self.kintoConfigs.headers)
  if headers != nil:
    extraHeaders.add(headers)
  let payload = $(%self)
  extraHeaders.add("Content-Length: " & $len(payload) & "\c\L")

  debug("Remote: ", actualUrl)
  debug("Header: ", extraHeaders)
  debug("Payload: ", payload)

  let response = request(actualUrl,
                         httpMethod,
                         extraHeaders,
                         payload,
                         userAgent=USER_AGENT,
                         proxy=self.kintoConfigs.proxy)

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

proc getCacheHeaders(self: KintoBase, safe: bool, lastModified = 0): string =
  result = ""
  if safe:
    var lastModified = lastModified
    if lastModified == 0 and self.lastModified > 0:
      lastModified = self.lastModified
      if safe and lastModified != 0:
        result = "If-Match: \"" & $lastModified & "\"\c\L"

proc bucket*(base: KintoBase, bucket: string): Bucket =
  ## Select the default bucket for current client
  if bucket.isNil:
    raise newException(ValueError, "Bucket name is required")
  result.kintoConfigs = base.kintoConfigs
  result.kintoConfigs.bucket = bucket
  result.id = bucket

proc collection*(base: KintoBase, collection: string): Collection =
  ## Return new Collection object
  if collection.isNil or collection == "":
    raise newException(ValueError, "Collection name is required")
  result.kintoConfigs = base.kintoConfigs
  result.kintoConfigs.collection = collection
  result.id = collection

proc getBuckets*(base: KintoBase): seq[Bucket] =
  ## Returns the list of accessible buckets
  result = @[]
  var (body, _) = base.request($httpGET, base.getEndpoint(BUCKETS_ENDPOINT))
  for node in body["data"].items:
    var b: Bucket
    b.kintoConfigs = base.kintoConfigs
    b.id = node["id"].str
    b.last_modified = node["last_modified"].num.int

    result.add(b)

proc load*(self: var Bucket) =
  ## Returns a specific bucket by its ID
  if !self.id:
    raise newException(ValueError, "Bucket name is empty")
  try:
    var (body, _) = self.request($httpGET, self.getEndpoint(BUCKET_ENDPOINT, self.id))

    self.lastModified = body["data"]["last_modified"].num.int
    self.permissions = newPermissions(body["permissions"])
  except KintoException:
    raise newException(BucketNotFoundException, "Bucket not found or not accessible: " & self.id)

proc create*(self: var Bucket) =
  ## Creates a new bucket. If id is not provided, it is automatically generated.
  var (body, _) = self.request("httpPOST", self.getEndpoint(BUCKETS_ENDPOINT))

  if not self.id.isNil and self.id != "":
    self.id = body["data"]["id"].str
  self.lastModified = body["data"]["last_modified"].num.int
  if body.hasKey("permission"):
    self.permissions = newPermissions(body["permissions"])

proc save*(self: var Bucket, safe = true, ifNotExists = false) =
  var headers = ""
  if ifNotExists:
    headers.add(DO_NOT_OVERWRITE)

  if safe:
    headers.add(self.getCacheHeaders(safe))

  var (body, _) = self.request("httpPUT", self.getEndpoint(BUCKET_ENDPOINT, self.id), headers=headers)
  self.id =  body["data"]["id"].str
  self.lastModified = body["data"]["last_modified"].num.int
  self.permissions = newPermissions(body["permissions"])

proc drop*(self: Bucket, safe = true, lastModified = 0) =
  let headers = self.getCacheHeaders(safe, lastModified=lastModified)
  var (body, _) = self.request($httpDELETE, self.getEndpoint(BUCKET_ENDPOINT, self.id), headers=headers)

discard """
proc getCollection*(self: KintoBase, collection, bucket = ""): JsonNode =
  var (body, _) = self.request($httpGET, self.getEndpoint(COLLECTION_ENDPOINT, bucket or self.bucket, collection))
  result = body

proc createCollection*(self: KintoBase, collection, bucket = ""): JsonNode =
  var data: JsonNode
  if collection != "":
    data = %*{"id": collection}

  var (body, _) = self.request($httpPOST, self.getEndpoint(COLLECTIONS_ENDPOINT, bucket or self.bucket), data=data)
  result = body

proc updateCollection*(self: KintoBase, collection: string, bucket = "", data, permissions: JsonNode = nil, safe = true, ifNotExists = false, lastModified = 0): JsonNode =
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

proc patchCollection*(self: KintoBase, collection: string, bucket = "", data, permissions: JsonNode = nil): JsonNode =
  var(body, _) = self.request("httpPATCH", self.getEndpoint(COLLECTION_ENDPOINT, bucket or self.bucket, collection), data=data, permissions=permissions)
  result = body

proc deleteCollection*(self: KintoBase, collection: string, bucket = "", safe = true, lastModified = 0): JsonNode =
  let headers = self.getCacheHeaders(safe, lastModified=lastModified)
  var (body, _) = self.request($httpDELETE, self.getEndpoint(COLLECTION_ENDPOINT, bucket or self.bucket, collection), headers=headers)
  result = body["data"]

proc getCollections*(self: KintoBase, bucket = ""): JsonNode =
  var (body, _) = self.request($httpGET, self.getEndpoint(COLLECTIONS_ENDPOINT, bucket or self.bucket))
  result = body

proc getRecord*(self: KintoBase, record: string, collection, bucket = ""): JsonNode =
  var (body, _) = self.request($httpGET, self.getEndpoint(RECORD_ENDPOINT, bucket or self.bucket, collection or self.collection, record))
  result = body

proc createRecord*(self: KintoBase, data: JsonNode, collection, bucket = "", permissions: JsonNode = nil): JsonNode =
  var (body, _) = self.request($httpPOST, self.getEndpoint(RECORDS_ENDPOINT, bucket or self.bucket, collection or self.collection), data=data, permissions=permissions)
  result = body

proc updateRecord*(self: KintoBase, record: string, data: JsonNode = nil, collection, bucket = "", permissions: JsonNode = nil, safe = true, ifNotExists = false, lastModified = 0): JsonNode =
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

proc patchRecord*(self: KintoBase, record: string, data: JsonNode = nil, collection, bucket = "", permissions: JsonNode = nil): JsonNode =
  var(body, _) = self.request("httpPATCH", self.getEndpoint(RECORD_ENDPOINT, bucket or self.bucket, collection or self.collection, record), data=data, permissions=permissions)
  result = body

proc deleteRecord*(self: KintoBase, record: string, collection, bucket = "", safe = true, lastModified = 0): JsonNode =
  let headers = self.getCacheHeaders(safe, lastModified=lastModified)
  var (body, _) = self.request($httpDELETE, self.getEndpoint(RECORD_ENDPOINT, bucket or self.bucket, collection or self.collection, record), headers=headers)
  result = body

proc deleteRecords*(self: KintoBase, record: string, collection, bucket = ""): JsonNode =
  var (body, _) = self.request($httpDELETE, self.getEndpoint(RECORD_ENDPOINT, bucket or self.bucket, collection or self.collection, record))
  result = body

proc getRecords*(self: KintoBase, collection, bucket = ""): JsonNode =
  var (body, _) = self.request($httpGET, self.getEndpoint(RECORDS_ENDPOINT, bucket or self.bucket, collection or self.collection))
  result = body

proc getGroup*(self: KintoBase, group: string, bucket = ""): JsonNode =
  var (body, _) = self.request($httpGET, self.getEndpoint(GROUP_ENDPOINT, bucket or self.bucket, group))
  result = body

proc createGroup*(self: KintoBase, data: JsonNode, bucket = ""): JsonNode =
  var (body, _) = self.request($httpPOST, self.getEndpoint(GROUPS_ENDPOINT, bucket or self.bucket), data=data)
  result = body

proc updateGroup*(self: KintoBase, group: string, data: JsonNode, bucket = "", permissions: JsonNode = nil, safe = true, ifNotExists = false, lastModified = 0): JsonNode =
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

proc deleteGroup*(self: KintoBase, group: string, bucket = "", safe = true, lastModified = 0): JsonNode =
  var (body, _) = self.request($httpDELETE, self.getEndpoint(GROUP_ENDPOINT, bucket or self.bucket, group))
  result = body

proc getGroups*(self: KintoBase, bucket = ""): JsonNode =
  var (body, _) = self.request($httpGET, self.getEndpoint(GROUPS_ENDPOINT, bucket or self.bucket))
  result = body
"""
