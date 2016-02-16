import unittest, httpclient, json
import ../kinto, ../util

suite "BucketTest":
  setUp:
    let bucket = "kinto1"
    let client = newKintoClient("https://ss.huy.im/v1", "kinto", "s3cret")

    var resp: JsonNode

  test "create bucket":
    resp = client.createBucket(bucket, ifNotExists = true)
    check resp["data"]["id"].str == bucket

  test "update bucket":
    resp = client.updateBucket(bucket, data = %*{"foo": "bar"})
    check resp["data"]["id"].str == bucket

  test "get bucket without permission":
    expect(BucketNotFoundException):
      resp = client.getBucket("this_bucket_is_not_exists")

  test "get bucket":
    resp = client.getBucket(bucket)
    check resp["data"]["id"].str == bucket

  test "delete bucket":
    resp = client.deleteBucket(bucket)
    check resp["deleted"].bval == true
