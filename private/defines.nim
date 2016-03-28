
const
  USER_AGENT* = "kinto.nim/0.2.1 (https://github.com/OpenSystemsLab/kinto.nim)"

  ROOT_ENDPOINT* =         "/"
  BATCH_ENDPOINT* =        "/batch"
  BUCKETS_ENDPOINT* =      "/buckets"
  BUCKET_ENDPOINT* =       "/buckets/$#"
  COLLECTIONS_ENDPOINT* =  "/buckets/$#/collections"
  COLLECTION_ENDPOINT* =   "/buckets/$#/collections/$#"
  RECORDS_ENDPOINT* =      "/buckets/$#/collections/$#/records"
  RECORD_ENDPOINT* =       "/buckets/$#/collections/$#/records/$#"
  GROUPS_ENDPOINT* =       "/buckets/$#/groups"
  GROUP_ENDPOINT* =        "/buckets/$#/groups/$#"


type
  httpMethod* = enum
    UNKNOWN
    GET
    POST
    PUT
    PATCH
    DELETE

proc `%`*(m: httpMethod): string =
  case m
  of UNKNOWN:
    "unknown"
  of GET:
    "httpGET"
  of POST:
    "httpPOST"
  of PUT:
    "httpPUT"
  of PATCH:
    "httpPATCH"
  of DELETE:
    "httpDELETE"
