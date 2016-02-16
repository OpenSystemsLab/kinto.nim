import httpclient, strtabs, strutils, json, uri, base64, logging
import util
type
  KintoException* = object of Exception
    response*: Response

  BucketNotFoundException* = KintoException

  KintoClient = ref object
    remote: string
    headers: string
    root: string
    bucket: string
    collection: string

const
  USER_AGENT = "kinto.nim/0.0.1"
  DO_NOT_OVERWRITE = "If-None-Match: \"*\"\c\L"

  ROOT =         "$#/"
  BATCH =        "$#/batch"
  BUCKETS =      "$#/buckets"
  BUCKET =       "$#/buckets/$#"
  COLLECTIONS =  "$#/buckets/$#/collections"
  COLLECTION =   "$#/buckets/$#/collections/$#"
  RECORDS =      "$#/buckets/$#/collections/$#/records"      # NOQA
  RECORD =       "$#/buckets/$#/collections/$#/records/$#"  # NOQA

when defined(debug):
  let L = newConsoleLogger()
  addHandler(L)

proc newKintoClient*(remote: string, username, password = "", bucket = "default", collection =""): KintoClient =
  new(result)

  result.remote = strip(remote, leading = false, chars={'/'}) & "/"
  result.headers = ""
  if username != "":
    result.headers.add("Authorization: Basic " & encode(username & ":" & password) & "\c\L")

  result.root = ""
  result.bucket = bucket
  result.collection = collection

proc getEndpoint(self: KintoClient, kind: string, bucket, collection, id=""): string =
  return kind % [
    self.root,
    if bucket != "": bucket else: self.bucket,
    if bucket != "": collection else: self.collection,
    id
  ]

#proc paginated(self: KintoClient, endpoint: string, records: JsonNode = nil, ifNoneMatch = 0

proc request(self: KintoClient, httpMethod, endpoint: string, data, permissions: JsonNode = nil, headers = ""): tuple[body: JsonNode, headers: StringTableRef] =
  let parsed = parseUri(endpoint)
  var actualUrl: string
  if parsed.scheme == "":
    actualUrl = self.remote & strip(endpoint, chars={'/'})
  else:
    actualUrl = endpoint

  var extraHeaders = ""
  extraHeaders.add(self.headers)
  extraHeaders.add(headers)

  var payload = newJObject()

  if not data.isNil:
    payload.fields.add((key: "data", val: data))

  if not permissions.isNil:
    payload.fields.add((key: "permissions", val: permissions))

  var tmp: string
  if payload.len > 0:
    tmp = $payload
    extraHeaders.add("Content-Length: " & $len(tmp) & "\c\L")
  else:
    tmp = ""

  debug("Header: ", extraHeaders)
  debug("Payload: ", tmp)

  let response = request(actualUrl,
                         httpMethod,
                         extraHeaders,
                         tmp,
                         userAgent=USER_AGENT)


  debug("Status: ", response.status)
  debug("Body: ", response.body)

  let body = parseJson(response.body)

  let status = response.getStatusCode()

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
    result = "If-Match: \"$#\"\c\L" % [$lastModified]

proc getBucket*(self: KintoClient, bucket: string): JsonNode =
  try:
    var (body, _) = self.request($httpGET, self.getEndpoint(BUCKET, bucket))
    result = body
  except KintoException:
    raise newException(BucketNotFoundException, bucket)

proc createBucket*(self: KintoClient, bucket = "", safe = true, ifNotExists = false): JsonNode =
  if ifNotExists:
    try:
      return self.createBucket(bucket, safe)
    except KintoException:
      let e = (ref KintoException)(getCurrentException())
      if e.response.getStatusCode() != 412:
        raise e
      result = self.getBucket(bucket)
      return

  let headers =
    if safe:
      DO_NOT_OVERWRITE
    else:
      ""
  let data =
    if bucket != "":
      %*{"id": bucket}
    else:
      nil

  var (body, _) = self.request($httpPOST, self.getEndpoint(BUCKETS), data=data, headers=headers)
  result = body

proc updateBucket*(self: KintoClient, bucket: string, data, permissions: JsonNode = nil, safe = true, lastModified = 0): JsonNode =
  let headers = self.getCacheHeaders(safe, data, lastModified)
  var (body, _) = self.request($httpPUT, self.getEndpoint(BUCKET, bucket), data=data, permissions=permissions, headers=headers)
  result = body


proc deleteBucket*(self: KintoClient, bucket: string, safe = true, lastModified = 0): JsonNode =
  let headers = self.getCacheHeaders(safe, lastModified=lastModified)
  var (body, _) = self.request($httpDELETE, self.getEndpoint(BUCKET, bucket), headers=headers)
  result = body["data"]

#proc getCollections(self: KintoClient, bucket = ""): JsonNode =
