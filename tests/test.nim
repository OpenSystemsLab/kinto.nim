import ../kinto, marshal, ../private/util.nim, ../../jsmn.nim/jsmn

type
  Direction = enum
    north, east, south, west

type
  Tasks* = object of Collection
    description*: string
    bits: uint32
    dir: Direction

var db = Kinto("http://ss.huy.im/v1", "kinto", "s3cret", "todo") #, proxy=("http://192.168.1.16:8888"))

var tasks = db.create(Tasks)
tasks.description = "Fuck yeah!"
db.save(tasks)
echo tasks
db.drop(tasks)
