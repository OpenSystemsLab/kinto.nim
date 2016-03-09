import httpclient, strutils, uri, base64, logging, typetraits, macros, ../sam.nim/sam
import private/util

type
  KintoException* = object of Exception
    ## Errors returned by server
    response*: Response
      ## responsed packet

  BucketNotFoundException* = KintoException
    ## Bucket not found or not accessible

  KintoClient = object
    remote: string
    headers: string
    bucket: string
    collection: string
    proxy: Proxy

  Permissions {.final.} = object
    read*: seq[string]
    write*: seq[string]
    create*: seq[string]

  Bucket* {.final.} = object
    ## Kinto bucket instance
    id: string
    last_modified: int
    permissions*: Permissions

  Collection* {.final.} = object
    ## Kinto collection instance
    id: string
    last_modified: int
    permissions*: Permissions

  Record* = object of RootObj
    ## Kinto record instance
    id: string
    last_modified: int
    permissions*: Permissions

  Group* {.final.} = object
    ## Kinto group instance
    id: string
    last_modified: int
    permissions*: Permissions
    members*: seq[string]

const
  USER_AGENT = "kinto.nim/0.0.2"
  DO_NOT_OVERWRITE = "If-None-Match: \"*\"\c\L"

  BATCH_ENDPOINT =        "/batch"
  BUCKETS_ENDPOINT =      "/buckets"
  BUCKET_ENDPOINT =       "/buckets/$#"
  COLLECTIONS_ENDPOINT =   "/buckets/$#/collections"
  COLLECTION_ENDPOINT =   "/buckets/$#/collections/$#"
  RECORDS_ENDPOINT =      "/buckets/$#/collections/$#/records"
  RECORD_ENDPOINT =       "/buckets/$#/collections/$#/records/$#"
  GROUPS_ENDPOINT =       "/buckets/$#/groups"
  GROUP_ENDPOINT =        "/buckets/$#/groups/$#"


when defined(debug):
  let L = newConsoleLogger()
  addHandler(L)

proc id*[T: Bucket|Collection|Record|Group](k: T): string {.inline.} =
  ## Getter of Object ID
  k.id

proc lastModified*[T: Bucket|Collection|Record|Group](k: T): int {.inline.} =
  ## Getter of last modified
  k.lastModified

proc newBuket*(id = ""): Bucket {.inline.} =
  if not empty(id):
    result.id = id

proc newCollection*(id = ""): Collection {.inline.} =
  if not empty(id):
    result.id = id

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

proc `%*`[T: Bucket|Collection|Record|Group](self: T): string =
  result = newStringOfCap(sizeof(self) shl 1)
  result.add "{\"data\":{"
  var
    v: string
    first = true
  for name, value in fieldPairs(self):
    when not (name in @["last_modified", "deleted", "permissions"]):
      v = value.dumps()
      if v != "null":
        if first:
          first = false
        else:
          result.add ","

        result.add "\"" & name & "\":"
        result.add value.dumps()
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
  kind % [a, b, c]


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

proc getCacheHeaders[T: Bucket|Collection|Record|Group](self: T, safe: bool, lastModified = 0): string =
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

proc collection*(self: var KintoClient, collection: string) =
  ## Return a Kinto Client with new collection
  if collection.isNil or collection == "":
    raise newException(ValueError, "Collection name is required")
  self.collection = collection

proc getBuckets*(self: KintoClient): seq[tuple[id: string, lastModified: int]] =
  ## Returns the list of accessible buckets
  result = @[]
  var node = self.request($httpGET, self.getEndpoint(BUCKETS_ENDPOINT))
  for n in node["data"].items:
    result.add((id: n["id"].toStr, lastModified: n{1}["last_modified"].toInt))

proc getCollections*(self: KintoClient): seq[tuple[id: string, lastModified: int]] =
  ## Returns the list of accessible collections
  result = @[]
  var node = self.request($httpGET, self.getEndpoint(COLLECTIONS_ENDPOINT, self.bucket))
  for n in node["data"].items:
    result.add((id: n["id"].toStr, lastModified: n{1}["last_modified"].toInt))

proc getRecords*(self: KintoClient): seq[tuple[id: string, lastModified: int]] =
  ## Returns the list of accessible records
  result = @[]
  var node = self.request($httpGET, self.getEndpoint(RECORDS_ENDPOINT, self.bucket, self.collection))
  for n in node["data"].items:
    result.add((id: n["id"].toStr, lastModified: n{1}["last_modified"].toInt))

proc get[T](self: KintoClient, endpoint: string): T =
  var node = self.request($httpGET, endpoint)
  result = toObj[T](node["data"])
  result.permissions = toObj[Permissions](node{}["permissions"])

proc getBucket*(self: KintoClient, id: string): Bucket {.inline.} =
  get[Bucket](self, self.getEndpoint(BUCKET_ENDPOINT, id))

proc getCollection*(self: KintoClient, id: string): Collection {.inline.} =
  get[Collection](self, self.getEndpoint(COLLECTION_ENDPOINT, self.bucket, id))

proc getRecord*[T: Record](self: KintoClient, id: string): T {.inline.} =
  get[T](self, self.getEndpoint(RECORD_ENDPOINT, self.bucket, self.collection, id))

proc save*[T: Bucket|Collection|Record|Group](self: KintoClient, obj: var T, safe = true, updateOnly = true, forceOverwrite = false) =
  ## Create or update an Kinto object
  var
    headers = ""
    httpMethod: string
    endpoint: string
    node: JsonNode

  if not forceOverwrite:
    headers.add(DO_NOT_OVERWRITE)
  if empty(obj.id):
    httpMethod = "httpPOST"
    when T is Bucket:
      endpoint = self.getEndpoint(BUCKETS_ENDPOINT)
    elif T is Collection:
      endpoint = self.getEndpoint(COLLECTIONS_ENDPOINT, self.bucket)
    elif T is Record:
      endpoint = self.getEndpoint(RECORDS_ENDPOINT, self.bucket, self.collection)
    else:
      raise newException(SystemError, "Invalid object type: " & type(T))
  else:
    if not updateOnly:
      httpMethod = "httpPATCH"
    else:
      httpMethod = "httpPUT"

    when T is Bucket:
      endpoint = self.getEndpoint(BUCKET_ENDPOINT, obj.id)
    elif T is Collection:
      endpoint = self.getEndpoint(COLLECTION_ENDPOINT, self.bucket, obj.id)
    elif T is Record:
      endpoint = self.getEndpoint(RECORD_ENDPOINT, self.bucket, self.collection, obj.id)
    else:
      raise newException(SystemError, "Invalid object type: " & type(T))

  headers.add(obj.getCacheHeaders(safe))
  node = self.request(httpMethod, endpoint, %*obj, headers=headers)

  if empty(obj.id):
    obj.id = node["data"]["id"].toStr
    obj.lastModified = node{1}["last_modified"].toInt
  else:
    obj.lastModified = node["data"]["last_modified"].toInt
  obj.permissions = toObj[Permissions](node{}["permissions"])

proc drop*[T: Bucket|Collection|Record|Group](self: KintoClient, obj: var T, safe = true, lastModified = 0) =
  ## Drop a Kinto object
  var endpoint: string
  when T is Bucket:
    endpoint = self.getEndpoint(BUCKET_ENDPOINT, id)
  elif T is Collection:
    endpoint = self.getEndpoint(COLLECTION_ENDPOINT, self.bucket, id)
  elif T is Record:
    endpoint = self.getEndpoint(RECORD_ENDPOINT, self.bucket, self.collection, id)
  else:
    raise newException(SystemError, "Invalid object type: " & type(T))

  let headers = collection.getCacheHeaders(safe, lastModified=lastModified)
  discard self.request($httpDELETE, endpoint, headers=headers)

proc dropBucket*(self: Kintoclient, id: string) =
  discard self.request($httpDELETE, self.getEndpoint(BUCKET_ENDPOINT, id))

proc dropCollection*(self: Kintoclient, id: string) =
  discard self.request($httpDELETE, self.getEndpoint(COLLECTION_ENDPOINT, self.bucket, id))

proc dropRecord*(self: Kintoclient, id: string) =
  discard self.request($httpDELETE, self.getEndpoint(RECORD_ENDPOINT, self.bucket, self.collection, id))

proc dropBuckets*(self: KintoClient) =
  discard self.request($httpDELETE, self.getEndpoint(BUCKETS_ENDPOINT))

proc dropCollections*(self: KintoClient) =
  discard self.request($httpDELETE, self.getEndpoint(COLLECTIONS_ENDPOINT, self.bucket))

proc dropRecords*(self: KintoClient) =
  discard self.request($httpDELETE, self.getEndpoint(RECORDS_ENDPOINT, self.bucket, self.collection))

proc dropGroups*(self: KintoClient) =
  discard self.request($httpDELETE, self.getEndpoint(GROUPS_ENDPOINT, self.bucket))
