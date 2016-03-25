import ../kinto, ../../sam.nim/sam

const js = """{"responses":[{"headers":{"Access-Control-Expose-Headers":"Backoff, Content-Length, Alert, Retry-After","Content-Type":"application/json; charset=UTF-8","Content-Length":"597"},"path":"/v1/buckets/default/collections/restaurants/records","status":201,"body":{"data":{"name":"Morris Park Bake Shop","id":"e7d37664-0f07-4d23-ab36-d673fa095aa3","address":{"street":"Morris Park Ave","zipcode":10462,"building":"1007","coord":[-73.856077,40.848447]},"cuisine":"Bakery","borough":"Bronx","grades":[{"date":1393804800000,"score":2,"grade":"A"},{"date":1378857600000,"score":6,"grade":"A"},{"date":1358985600000,"score":10,"grade":"A"},{"date":1322006400000,"score":9,"grade":"A"},{"date":1299715200000,"score":14,"grade":"B"}],"last_modified":1458785522790},"permissions":{"write":["basicauth:bf920aee71e818736f03b12a19e143f255c27b2fa272773b491478e831433b6b"]}}},{"headers":{"Access-Control-Expose-Headers":"Backoff, Content-Length, Alert, Retry-After","Content-Type":"application/json; charset=UTF-8","Content-Length":"545"},"path":"/v1/buckets/default/collections/restaurants/records","status":201,"body":{"data":{"name":"Wendy'S","id":"cdd355f6-ffbf-4f50-86b7-18b039023fc4","address":{"street":"Flatbush Avenue","zipcode":11225,"building":"469","coord":[-73.961704,40.662942]},"cuisine":"Hamburgers","borough":"Brooklyn","grades":[{"date":1419897600000,"score":8,"grade":"A"},{"date":1404172800000,"score":23,"grade":"B"},{"date":1367280000000,"score":12,"grade":"A"},{"date":1336435200000,"score":12,"grade":"A"}],"last_modified":1458785522811},"permissions":{"write":["basicauth:bf920aee71e818736f03b12a19e143f255c27b2fa272773b491478e831433b6b"]}}}]}"""

var
  ret = newSeq[Response](2)
  json = parse(js)

ret.loads(json["responses"])
echo ret
