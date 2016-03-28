import kinto, private/defines, private/util
import strtabs, strutils, sam
from json import escapeJson

type
  Body* = tuple
    permissions: Permissions
    data: JsonNode

  Request = object
    httpMethod: httpMethod
    path: string
    data: string
    perms: string
    headers: StringTableRef

  Response* = object
    headers*: JsonNode
    body*: Body
    status*: int
    path*: string

  KintoBatchClient = ref object
    client: KintoClient
    default: Request
    requests: seq[Request]


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


proc batch*(self: KintoClient, httpMethod = POST, path = "", headers: StringTableRef = nil): KintoBatchClient =
  new(result)
  result.client = self
  result.default.httpMethod = httpMethod
  result.default.path = path
  result.default.headers = headers
  result.requests = @[]

proc request(self: KintoBatchClient, httpMethod: httpMethod, endpoint: string, data, perms = "", headers: StringTableRef = nil) =
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
    tmp = newSeq[Response](self.client.getSettings.batch_max_requests)

  for i in 0..<self.requests.len:
    requests.add %self.requests[i]

    if requests.len >= self.requests.len or  requests.len >= self.client.getSettings.batch_max_requests:
      var data = $${
        "default": %self.default,
        "requests": requests
      }
      requests = @[]
      let (node, _) = self.client.request(POST, getEndpoint(BATCH_ENDPOINT), data)
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

proc getRecord*(self: KintoBatchClient, id: string) =
  get(self, getEndpoint(RECORD_ENDPOINT, self.client.bucket, self.client.collection, id))

proc save*[T: Bucket|Collection|Record|Group](self: KintoBatchClient, obj: var T, safe = true, updateOnly = true, forceOverwrite = false) =
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
