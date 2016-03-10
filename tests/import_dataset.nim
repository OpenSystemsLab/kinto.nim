import ../kinto, ../../sam.nim/sam

type
  Restaurant = object of Record
    address: tuple[building: string, coord: array[2, float], street: string, zipcode: int]
    borough: string
    cuisine: string
    grades: seq[tuple[date: int, grade: char, score: int]]
    name: string

var
  db = Kinto("https://ss.huy.im/v1", "kinto", "s3cret", "default") #, proxy=("http://192.168.1.16:8888"))

#db.save(newCollection("restaurants"))
db.collection("restaurants")
db.dropRecords()

var r: Restaurant
for js in lines("dataset.json"):
  r.id = nil
  r.loads(js)
  db.save(r)
