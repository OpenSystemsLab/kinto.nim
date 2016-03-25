import httpclient, strutils, uri, base64, logging, typetraits, macros, strtabs, ../sam.nim/sam
from json import escapeJson
import private/util

type

  HTTP_METHOD = enum
    UNKNOWN
    GET
    POST
    PUT
    PATCH
    DELETE


  KintoException* = object of Exception
    ## Errors returned by server
    response*: httpclient.Response
      ## responsed packet

  BucketNotFoundException* = KintoException
    ## Bucket not found or not accessible

  Settings = object
    readonly: bool
    batch_max_requests: int

  KintoClient = object
    remote: string
    headers: StringTableRef
    bucket: string
    collection: string
    proxy: Proxy
    settings: Settings

  Request = object
    httpMethod: HTTP_METHOD
    path: string
    data: string
    perms: string
    headers: StringTableRef

  Body* = tuple
    permissions: Permissions
    data: JsonNode

  Response* = object
    path*: string
    status*: int
    body*: Body
    headers*: StringTableRef

  KintoBatchClient = ref object
    client: KintoClient
    default: Request
    requests: seq[Request]


  Permissions* {.final.} = object
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
    id*: string
    last_modified*: int
    permissions*: Permissions

  Group* {.final.} = object
    ## Kinto group instance
    id: string
    last_modified: int
    permissions*: Permissions
    members*: seq[string]

const
  USER_AGENT = "kinto.nim/0.1.1"

  ROOT_ENDPOINT =         "/"
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

proc `%`(m: HTTP_METHOD): string =
  "http" & $m


proc id*[T: Bucket|Collection](k: T): string {.inline.} =
  ## Getter of Object ID
  k.id

proc lastModified*[T: Bucket|Collection](k: T): int {.inline.} =
  ## Getter of last modified
  k.lastModified

proc newBuket*(id = ""): Bucket {.inline.} =
  if not empty(id):
    result.id = id

proc newCollection*(id = ""): Collection {.inline.} =
  if not empty(id):
    result.id = id

proc `%%`[T: Bucket|Collection|Record|Group](self: T): string =
  result = newStringOfCap(sizeof(self) shl 1)
  result.add "{"
  var
    v: string
    first = true
  for name, value in fieldPairs(self):
    when not (name in @["last_modified", "deleted", "permissions"]):
      v = dumps(value)
      if v != "null":
        if first:
          first = false
        else:
          result.add ","

        result.add "\"" & name & "\":"
        result.add v
  result.add "}"

proc `%`(req: Request): JsonRaw {.inline.} =
  var first = true
  var ret = "{"
  if req.httpMethod == UNKNOWN:
    ret.add "\"method\":\"POST\""
  else:
    ret.add "\"method\":\"" & $req.httpMethod & "\""
  if not empty(req.path):
    ret.add ",\"path\":"
    ret.add escapeJson(req.path)
  if not req.headers.isNil and len(req.headers) > 0:
    ret.add ",\"headers\":{"
    for k, v in req.headers.pairs():
      if first:
        first = false
      else:
        ret.add ","
      ret.add escapeJson(k) & ":" & escapeJson(v)
    ret.add "}"
  if not empty(req.data) or not empty(req.perms):
    ret.add ",\"body\":{"
    if not empty(req.data):
      ret.add "\"data\":"
      ret.add req.data
    if not empty(req.perms):
      if not empty(req.data):
        ret.add ","
      ret.add "\"permissions\":"
      ret.add req.perms
    ret.add "}"

  ret.add "}"
  (JsonRaw)ret

proc getEndpoint(kind: string, a, b, c = ""): string {.inline, noSideEffect.} =
  kind % [a, b, c]


proc request(self: KintoClient, httpMethod: HTTP_METHOD, endpoint: string, data, perms = "", headers: StringTableRef = nil): JsonNode =
  let parsed = parseUri(endpoint)
  var actualUrl: string
  if parsed.scheme == "":
    actualUrl = self.remote & endpoint
  else:
    actualUrl = endpoint

  var extraHeaders = ""
  if not self.headers.isNil and self.headers.len > 0:
    for k, v in self.headers.pairs():
      extraHeaders.add k & ": " & v & "\c\L"
  if not headers.isNil and headers.len > 0:
    for k, v in self.headers.pairs():
      extraHeaders.add k & ": " & v & "\c\L"

  let payload = if data.isNil: "" else: $data
  extraHeaders.add("Content-Length: " & $len(payload) & "\c\L")

  debug("-------------------------------------")
  debug(httpMethod, " ", actualUrl)
  debug(extraHeaders)
  debug(payload)

  let response = request(actualUrl,
                         %httpMethod,
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

proc Kinto*(remote: string, username, password = "", bucket = "default", collection = "", proxy: tuple[url: string, auth: string]): KintoClient =
  ## Create new Kinto API client with proxy configurated
  result.remote = strip(remote, leading = false, chars={'/'})
  result.headers = newStringTable({"Content-Type": "application/json", "Accept": "application/json"}, modeCaseInsensitive)
  if username != "":
    result.headers["Authorization"] = "basic " & encode(username & ":" & password)

  result.bucket = bucket
  result.collection = collection

  if proxy[0] != "":
    result.proxy = newProxy(proxy[0], proxy[1])

  let ret = result.request(GET, result.remote & ROOT_ENDPOINT)
  result.settings = toObj[Settings](ret["settings"])


template Kinto*(remote: string, username, password = "", bucket = "default", collection = "", proxy: string): expr =
  ## Create new Kinto API client with proxy that not requires authentication
  Kinto(remote, username, password, bucket, collection, (proxy, ""))

template Kinto*(remote: string, username, password = "", bucket = "default", collection = ""): expr =
  ## Create new Kinto API client
  Kinto(remote, username, password, bucket, collection, ("", ""))


proc getCacheHeaders[T: Bucket|Collection|Record|Group](self: T, headers: StringTableRef, safe: bool, lastModified = 0) =
  if safe:
    var lastModified = lastModified
    if lastModified == 0 and self.lastModified > 0:
      lastModified = self.lastModified
    if lastModified != 0:
      headers["If-Match"] = "\"" & $lastModified & "\""

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
  var node = self.request(GET, getEndpoint(BUCKETS_ENDPOINT))
  for n in node["data"].items:
    result.add((id: n["id"].toStr, lastModified: n{1}["last_modified"].toInt))

proc getCollections*(self: KintoClient): seq[tuple[id: string, lastModified: int]] =
  ## Returns the list of accessible collections
  result = @[]
  var node = self.request(GET, getEndpoint(COLLECTIONS_ENDPOINT, self.bucket))
  for n in node["data"].items:
    result.add((id: n["id"].toStr, lastModified: n{1}["last_modified"].toInt))

proc getRecords*(self: KintoClient): seq[tuple[id: string, lastModified: int]] =
  ## Returns the list of accessible records
  result = @[]
  var node = self.request(GET, getEndpoint(RECORDS_ENDPOINT, self.bucket, self.collection))
  for n in node["data"].items:
    result.add((id: n["id"].toStr, lastModified: n{1}["last_modified"].toInt))

proc get[T](self: KintoClient, endpoint: string): T =
  var node = self.request(GET, endpoint)
  result = toObj[T](node["data"])
  result.permissions = toObj[Permissions](node{}["permissions"])

proc getBucket*(self: KintoClient, id: string): Bucket =
  get[Bucket](self, getEndpoint(BUCKET_ENDPOINT, id))

proc getCollection*(self: KintoClient, id: string): Collection =
  get[Collection](self, getEndpoint(COLLECTION_ENDPOINT, self.bucket, id))

proc getRecord*[T: Record](self: KintoClient, id: string): T =
  get[T](self, getEndpoint(RECORD_ENDPOINT, self.bucket, self.collection, id))

proc save*[T: Bucket|Collection|Record|Group](self: KintoClient, obj: var T, safe = true, updateOnly = true, forceOverwrite = false) =
  ## Create or update an Kinto object
  var
    headers = newStringTable()
    httpMethod: HTTP_METHOD
    endpoint: string
    node: JsonNode

  if not forceOverwrite:
    headers["If-None-Match"] = "\"*\""

  if empty(obj.id):
    httpMethod = POST
    when T is Bucket:
      endpoint = getEndpoint(BUCKETS_ENDPOINT)
    elif T is Collection:
      endpoint = getEndpoint(COLLECTIONS_ENDPOINT, self.bucket)
    elif T is Record:
      endpoint = getEndpoint(RECORDS_ENDPOINT, self.bucket, self.collection)
    else:
      raise newException(SystemError, "Invalid object type: " & type(T))
  else:
    if not updateOnly:
      httpMethod = PATCH
    else:
      httpMethod = PUT

    when T is Bucket:
      endpoint = getEndpoint(BUCKET_ENDPOINT, obj.id)
    elif T is Collection:
      endpoint = getEndpoint(COLLECTION_ENDPOINT, self.bucket, obj.id)
    elif T is Record:
      endpoint = getEndpoint(RECORD_ENDPOINT, self.bucket, self.collection, obj.id)
    else:
      raise newException(SystemError, "Invalid object type: " & type(T))

  obj.getCacheHeaders(headers, safe)
  node = self.request(httpMethod, endpoint, $obj, headers=headers)

  if empty(obj.id):
    obj.id = node["data"]["id"].toStr
    obj.lastModified = node{1}["last_modified"].toInt
  else:
    obj.lastModified = node["data"]["last_modified"].toInt
  obj.permissions = toObj[Permissions](node{}["permissions"])

proc drop*[T: Bucket|Collection|Record|Group](self: KintoClient, obj: var T, safe = true, lastModified = 0) =
  ## Drop a Kinto object
  var
    headers = newStringTable()
    endpoint: string
  when T is Bucket:
    endpoint = getEndpoint(BUCKET_ENDPOINT, id)
  elif T is Collection:
    endpoint = getEndpoint(COLLECTION_ENDPOINT, self.bucket, id)
  elif T is Record:
    endpoint = getEndpoint(RECORD_ENDPOINT, self.bucket, self.collection, id)
  else:
    raise newException(SystemError, "Invalid object type: " & type(T))

  collection.getCacheHeaders(headers, safe, lastModified=lastModified)
  discard self.request(DELETE, endpoint, headers=headers)

proc dropBucket*(self: Kintoclient, id: string) =
  discard self.request(DELETE, getEndpoint(BUCKET_ENDPOINT, id))

proc dropCollection*(self: Kintoclient, id: string) =
  discard self.request(DELETE, getEndpoint(COLLECTION_ENDPOINT, self.bucket, id))

proc dropRecord*(self: Kintoclient, id: string) =
  discard self.request(DELETE, getEndpoint(RECORD_ENDPOINT, self.bucket, self.collection, id))

proc dropBuckets*(self: KintoClient) =
  discard self.request(DELETE, getEndpoint(BUCKETS_ENDPOINT))

proc dropCollections*(self: KintoClient) =
  discard self.request(DELETE, getEndpoint(COLLECTIONS_ENDPOINT, self.bucket))

proc dropRecords*(self: KintoClient) =
  discard self.request(DELETE, getEndpoint(RECORDS_ENDPOINT, self.bucket, self.collection))

proc dropGroups*(self: KintoClient) =
  discard self.request(DELETE, getEndpoint(GROUPS_ENDPOINT, self.bucket))

proc batch*(self: KintoClient, httpMethod = POST, path = "", headers: StringTableRef = nil): KintoBatchClient =
  new(result)
  result.client = self
  result.default.httpMethod = httpMethod
  result.default.path = path
  result.default.headers = headers
  result.requests = @[]

proc request(self: KintoBatchClient, httpMethod: HTTP_METHOD, endpoint: string, data, perms = "", headers: StringTableRef = nil) =
  var req: Request
  req.httpMethod = httpMethod
  req.path = endpoint
  req.data = data
  req.perms = perms
  req.headers = headers

  self.requests.add(req)

proc send*(self: KintoBatchClient): seq[Response] =
  result = @[]
  var
    requests: seq[JsonRaw] = @[]
    tmp = newSeq[Response](self.client.settings.batch_max_requests)

  for i in 0..<self.requests.len:
    requests.add %self.requests[i]

    if requests.len >= self.requests.len or  requests.len >= self.client.settings.batch_max_requests:
      var data = $${
        "default": %self.default,
        "requests": requests
      }
      requests = @[]
      var node = self.client.request(POST, getEndpoint(BATCH_ENDPOINT), data)
      tmp.loads(node["responses"])
      result.add(tmp)

proc getBuckets*(self: KintoBatchClient) =
  ## Returns the list of accessible buckets
  self.request(GET, getEndpoint(BUCKETS_ENDPOINT))

proc getCollections*(self: KintoBatchClient) =
  ## Returns the list of accessible collections
  self.request(GET, getEndpoint(COLLECTIONS_ENDPOINT, self.client.bucket))

proc getRecords*(self: KintoBatchClient) =
  ## Returns the list of accessible records
  self.request(GET, getEndpoint(RECORDS_ENDPOINT, self.client.bucket, self.client.collection))

proc get(self: KintoBatchClient, endpoint: string) =
  self.request(GET, endpoint)

proc getBucket*(self: KintoBatchClient, id: string) =
  get(self, getEndpoint(BUCKET_ENDPOINT, id))

proc getCollection*(self: KintoBatchClient, id: string) =
  get(self, getEndpoint(COLLECTION_ENDPOINT, self.client.bucket, id))

proc getRecord*[T: Record](self: KintoBatchClient, id: string) =
  get(self, getEndpoint(RECORD_ENDPOINT, self.client.bucket, self.client.collection, id))

proc save*[T: Bucket|Collection|Record|Group](self: KintoBatchClient, obj: var T, safe = true, updateOnly = true, forceOverwrite = false) =
  ## Create or update an Kinto object
  var
    headers = newStringTable()
    httpMethod: HTTP_METHOD
    endpoint: string
    node: JsonNode

  if not forceOverwrite:
    headers["If-None-Match"] = "\"*\""
  if empty(obj.id):
    httpMethod = POST
    when T is Bucket:
      endpoint = getEndpoint(BUCKETS_ENDPOINT)
    elif T is Collection:
      endpoint = getEndpoint(COLLECTIONS_ENDPOINT, self.client.bucket)
    elif T is Record:
      endpoint = getEndpoint(RECORDS_ENDPOINT, self.client.bucket, self.client.collection)
    else:
      raise newException(SystemError, "Invalid object type: " & type(T))
  else:
    if not updateOnly:
      httpMethod = PATCH
    else:
      httpMethod = PUT

    when T is Bucket:
      endpoint = getEndpoint(BUCKET_ENDPOINT, obj.id)
    elif T is Collection:
      endpoint = getEndpoint(COLLECTION_ENDPOINT, self.client.bucket, obj.id)
    elif T is Record:
      endpoint = getEndpoint(RECORD_ENDPOINT, self.client.bucket, self.client.collection, obj.id)
    else:
      raise newException(SystemError, "Invalid object type: " & type(T))

  obj.getCacheHeaders(headers, safe)
  self.request(httpMethod, endpoint, %%obj, headers=headers)

proc drop*[T: Bucket|Collection|Record|Group](self: KintoBatchClient, obj: var T, safe = true, lastModified = 0) =
  ## Drop a Kinto object
  var
    headers = newStringTable()
    endpoint: string
  when T is Bucket:
    endpoint = getEndpoint(BUCKET_ENDPOINT, id)
  elif T is Collection:
    endpoint = getEndpoint(COLLECTION_ENDPOINT, self.client.bucket, id)
  elif T is Record:
    endpoint = getEndpoint(RECORD_ENDPOINT, self.client.bucket, self.client.collection, id)
  else:
    raise newException(SystemError, "Invalid object type: " & type(T))

  collection.getCacheHeaders(headers,safe, lastModified=lastModified)
  self.request(DELETE, endpoint, headers=headers)

proc dropBucket*(self: KintoBatchClient, id: string) =
  self.request(DELETE, getEndpoint(BUCKET_ENDPOINT, id))

proc dropCollection*(self: KintoBatchClient, id: string) =
  self.request(DELETE, getEndpoint(COLLECTION_ENDPOINT, self.client.bucket, id))

proc dropRecord*(self: KintoBatchClient, id: string) =
  self.request(DELETE, getEndpoint(RECORD_ENDPOINT, self.client.bucket, self.client.collection, id))

proc dropBuckets*(self: KintoBatchClient) =
  self.request(DELETE, getEndpoint(BUCKETS_ENDPOINT))

proc dropCollections*(self: KintoBatchClient) =
  self.request(DELETE, getEndpoint(COLLECTIONS_ENDPOINT, self.client.bucket))

proc dropRecords*(self: KintoBatchClient) =
  self.request(DELETE, getEndpoint(RECORDS_ENDPOINT, self.client.bucket, self.client.collection))

proc dropGroups*(self: KintoBatchClient) =
  self.request(DELETE, getEndpoint(GROUPS_ENDPOINT, self.client.bucket))
