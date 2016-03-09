import ../kinto

type
  Task = object of Record
    title: string
    cost: int
    done: bool

var db = Kinto("https://ss.huy.im/v1", "kinto", "s3cret", "default") #, proxy=("http://192.168.1.16:8888"))
db.collection("todo")

var t: Task
t.title = "Filter records"
t.cost = 10
t.done = true
db.save(t)


for r in db.getRecords():
  echo r
