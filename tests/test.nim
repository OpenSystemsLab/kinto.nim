import ../kinto, marshal, ../private/util.nim

type
  Task = object of Record
    title: string
    done: bool

var db = Kinto("https://ss.huy.im/v1", "kinto", "s3cret", "default") #, proxy=("http://192.168.1.16:8888"))
db.collection("todo")

for r in db.getRecords():
  db.dropRecord(r.id)
