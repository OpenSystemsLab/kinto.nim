import strutils, uri, base64, logging, typetraits, macros, strtabs, sam
import httpclient except httpMethod
from json import escapeJson
import private/defines, private/util, private/exception
export KintoException, BucketNotFoundException

type
  Settings* = object
    readonly*: bool
    batch_max_requests*: int

  KintoClient* = object
    remote: string
    headers: StringTableRef
    bucket: string
    collection: string
    proxy: Proxy
    settings: Settings

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

  Query*[T] = ref object
    client: KintoClient
    endpoint: string
    filters: seq[string]


when defined(debug):
  let L = newConsoleLogger()
  addHandler(L)

proc getSettings*(self: KintoClient): Settings =
  self.settings

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

proc `%%`*[T: Bucket|Collection|Record|Group](self: T): string =
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

proc request*(self: KintoClient, httpMethod: httpMethod, endpoint: string, data, perms = "", headers: StringTableRef = nil, query = ""): (JsonNode, StringTableRef) =
  let parsed = parseUri(endpoint)
  var
    actualUrl: string
    extraHeaders = ""

  if parsed.scheme == "":
    actualUrl = self.remote & endpoint
  else:
    actualUrl = endpoint

  if query != "":
    actualUrl.add("?" & query)

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
  debug("Headers: ", $response.headers)
  debug("Body: ", response.body)

  let node = parse(response.body)
  let status = response.getStatusCode()

  if status < 200 or status >= 400:
    let error = newException(KintoException, $status & " - " & node["message"].toStr)
    error.response = response
    raise error

  (node, response.headers)

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

  let (ret, _) = result.request(GET, result.remote & ROOT_ENDPOINT)
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

proc bucket*(self: KintoClient): string =
  self.bucket

proc collection*(self: KintoClient): string =
  self.collection

proc query*[T](typ: typedesc[T], client: KintoClient, coll = ""): Query[T] =
  ## init new query object
  new(result)
  result.client = client
  result.filters = @[]

  if coll != "":
    result.client.collection = coll

proc get*[T](q: Query[T], id: string): T =
  when T is Bucket:
    let endpoint = getEndpoint(BUCKET_ENDPOINT, id)
  elif T is Collection:
    let endpoint = getEndpoint(COLLECTION_ENDPOINT, q.client.bucket, id)
  else:
    let endpoint = getEndpoint(RECORD_ENDPOINT, q.client.bucket, q.client.collection, id)
  var (node, _) = q.client.request(GET, endpoint)
  result = toObj[T](node["data"])
  result.permissions = toObj[Permissions](node{}["permissions"])

proc limit*(q: Query, lm: int): Query {.inline.}  =
  ## limit number of records returned per request
  result = q
  result.filters.add "_limit=" & $lm

proc filter_by*(q: Query, field: string, value: string): Query {.inline.} =
  result = q
  result.filters.add(field & "=" & value)

proc min*(q: Query, field: string, value: string): Query {.inline.} =
  result = q
  result.filters.add("min_" & field & "=" & value)

proc max*(q: Query, field: string, value: string): Query {.inline.} =
  result = q
  result.filters.add("max_" & field & "=" & value)

proc lt*(q: Query, field: string, value: int): Query {.inline.} =
  result = q
  result.filters.add("lt_" & field & "=" & $value)

proc gt*(q: Query, field: string, value: int): Query {.inline.} =
  result = q
  result.filters.add("gt_" & field & "=" & $value)

proc any*(q: Query, field: string, value: varargs[string]): Query {.inline.} =
  result = q
  var
    first = true
    filter = "in_" & field & "="

  for x in value:
    if first:
      first = false
    else:
      filter.add ","
    filter.add x

  result.filters.add(filter)

proc exclude*(q: Query, field: string, values: varargs[auto]): Query {.inline.} =
  result = q
  if values.len == 1:
    result.filters.add("not_" & field & "=" & $values[0])
  else:
    var value = ""
    var first = true
    for x in values:
      if first:
        first = false
      else:
        value.add ","
      value.add x
    result.filters.add("exclude_" & field & "=" & value)

proc sort*(q: Query, fields: varargs[string]): Query {.inline.} =
  result = q
  var
    filter = "_sort="
    first = true
  for x in fields:
    if first:
      first = false
    else:
      filter.add ","
    filter.add x
  result.filters.add(filter)

macro filter*(q, n: expr): expr {.immediate.} =
  ## apply filters for records
  const infixOps = [
    ("==",  "filter_by"),
    ("<=",  "min"),
    (">=",   "max"),
    ("<", "lt"),
    (">",  "gt"),
    ("in", "any"),
    ("!=", "exclude"),
    ("notin", "exclude")
  ]
  result = newNimNode(nnkStmtList, n)

  var
    op: string
    fun: string
    field: string
    value: string
    node: NimNode
    first = true

  for i in 0..n.len-1:
    node = n[i]
    if n[i].kind == nnkInfix:
       fun = ""
       op = $(n[i][0])
       field = $(n[i][1])
       for j in 0..infixOps.len-1:
         if op == infixOps[j][0]:
           fun = infixOps[j][1]
       if fun == "":
         raise newException(KeyError, "unsupported operator: " & op)
       value = nimNodeToString(node[2])
       if first:
         first = false
         result.add newCall(fun, q, newStrLitNode(field), newStrLitNode(value))
       else:
         result.add newCall(fun, result.last, newStrLitNode(field), newStrLitNode(value))
    else:
      raise newException(ValueError, "invalid expression")
  result = result.last

proc all*[T](q: Query[T]): seq[T] =
  ## return all results
  result = @[]

  var query = ""

  if q.filters.len > 0:
    var first = true
    for x in q.filters:
      if first:
        first = false
      else:
        query.add "&"
      query.add x

  when T is Bucket:
    let endpoint = getEndpoint(BUCKETS_ENDPOINT)
  elif T is Collection:
    let endpoint = getEndpoint(COLLECTIONS_ENDPOINT, q.client.bucket)
  else:
    let endpoint = getEndpoint(RECORDS_ENDPOINT, q.client.bucket, q.client.collection)

  var (node, headers) = q.client.request(GET, endpoint, query=query)
  for n in node["data"].items:
    result.add toObj[T](n)
  while headers.hasKey("next-page"):
    (node, headers) = q.client.request(GET, headers["next-page"])
    for n in node["data"].items:
      result.add toObj[T](n)

proc save*[T: Bucket|Collection|Record|Group](self: KintoClient, obj: var T, safe = true, updateOnly = true, forceOverwrite = false) =
  ## Create or update an Kinto object
  var
    headers = newStringTable()
    httpMethod: httpMethod
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

proc delete*[T: Bucket|Collection|Record|Group](self: KintoClient, obj: var T, safe = true, lastModified = 0) =
  ## Delete a Kinto object
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
