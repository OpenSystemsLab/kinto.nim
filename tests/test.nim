import ../kinto, macros

type
  Restaurant = object of Record
    address: tuple[building: string, coord: array[2, float], street: string, zipcode: string]
    borough: string
    cuisine: string
    grades: seq[tuple[date: int, grade: char, score: int]]
    name: string

var db = Kinto("https://ss.huy.im/v1", "kinto", "s3cret", "default")

for r in Restaurant.query(db, "restaurants").filter((borough == "Queens", name != "", cuisine in ["1","2","3","4"], grades notin ["1",2])).all():
  echo r.id
