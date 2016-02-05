import httpclient, strtabs, strutils, json, uri, base64
import util
type
  KintoException* = object of Exception
    response*: Response

  BucketNotFoundException* = KintoException

  KintoClient = ref object
    serverUrl: string
    root: string
    auth: string
    bucket: string
    collection: string

const
  USER_AGENT = "kinto.nim/0.0.1"
  DO_NOT_OVERWRITE = "If-None-Match: *\c\L"

  ROOT =         "$#/"
  BATCH =        "$#/batch"
  BUCKETS =      "$#/buckets"
  BUCKET =       "$#/buckets/$#"
  COLLECTIONS =  "$#/buckets/$#/collections"
  COLLECTION =   "$#/buckets/$#/collections/$#"
  RECORDS =      "$#/buckets/$#/collections/$#/records"      # NOQA
  RECORD =       "$#/buckets/$#/collections/$#/records/$#"  # NOQA


proc newKintoClient*(serverUrl: string, username, password = "", bucket = "default", collection =""): KintoClient =
  new(result)

  result.serverUrl = strip(serverUrl, leading = false, chars={'/'}) & "/"
  result.root = ""
  if username != "":
    result.auth = "Authorization: Basic " & encode(username & ":" & password) & "\c\L"
  result.bucket = bucket
  result.collection = collection

proc getEndpoint(self: KintoClient, kind: string, bucket, collection, id=""): string =
  return kind % [
    self.root,
    if bucket != "": bucket else: self.bucket,
    if bucket != "": collection else: self.collection,
    id
  ]

proc request(self: KintoClient, httpMethod, endpoint: string, data, permissions: JsonNode = nil, headers = ""): tuple[body: JsonNode, headers: StringTableRef] =
  let parsed = parseUri(endpoint)
  var actualUrl: string
  if parsed.scheme == "":
    actualUrl = self.serverUrl & strip(endpoint, chars={'/'})
  else:
    actualUrl = endpoint

  var extraHeaders = ""
  if not self.auth.isNil:
    extraHeaders.add(self.auth)


  var payload = newJObject()

  if not data.isNil:
    payload.fields.add((key: "data", val: data))

  if not permissions.isNil:
    payload.fields.add((key: "permissions", val: permissions))

  let response = request(actualUrl,
                         httpMethod,
                         extraHeaders,
                         if payload.len > 0: $payload else: "",
                         userAgent=USER_AGENT)


  echo "Status: ", response.status
  echo "Body: ", response.body
  let status = response.getStatusCode()

  let body = parseJson(response.body)

  if status < 200 or status >= 400:
    let error = newException(KintoException, "$# - $#" % [$status, body["message"].str])
    error.response = response
    raise error

  if status == 304:
    result = (newJNull(), response.headers)
  else:
    result = (body, response.headers)

proc getCacheHeaders(self: KintoClient, safe: bool, data: JsonNode = nil, lastModified = 0): string =
  var lastModified = lastModified
  if lastModified != 0 and (not data.isNil and data.hasKey("last_modified")):
    lastModified = getNum(data["last_modified"]).int
  if safe and not lastModified != 0:
    result = "If-Match: " & $lastModified & "\c\L"

proc createBucket*(self: KintoClient, bucket: string, data, permissions: JsonNode = nil, safe = true, ifNotExists = false): JsonNode =
  if ifNotExists:
    try:
      return self.createBucket(bucket, data, permissions, safe)
    except KintoException:
      let e = cast[KintoException](getCurrentException())
      if e.response.getStatusCode() != 412:
        raise

  let headers = if safe: DO_NOT_OVERWRITE else: ""
  var (body, _) = self.request($httpPUT, self.getEndpoint(BUCKET, bucket), data=data, permissions=permissions, headers=headers)
  result = body

proc updateBucket*(self: KintoClient, bucket: string, data, permissions: JsonNode = nil, safe = true, lastModified = 0): JsonNode =
  let headers = self.getCacheHeaders(safe, data, lastModified)
  var (body, _) = self.request($httpPUT, self.getEndpoint(BUCKET, bucket), data=data, permissions=permissions, headers=headers)
  result = body

proc getBucket*(self: KintoClient, bucket: string): JsonNode =
  try:
    var (body, _) = self.request($httpGET, self.getEndpoint(BUCKET, bucket))
    result = body
  except KintoException:
    raise newException(BucketNotFoundException, bucket)

proc deleteBucket*(self: KintoClient, bucket: string, safe = true, lastModified = 0): JsonNode =
  let headers = self.getCacheHeaders(safe, lastModified=lastModified)
  var (body, _) = self.request($httpDELETE, self.getEndpoint(BUCKET, bucket), headers=headers)
  result = body["data"]
