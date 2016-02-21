import ../kinto, marshal, json, ../private/util.nim

type
  Direction = enum
    north, east, south, west

type
  Tasks = object of Collection
    description: string
    bits: uint32
    dir: Direction

#var db = Kinto("http://ss.huy.im/v1", "kinto", "s3cret", "todo") #, proxy=("http://192.168.1.16:8888"))
#var tasks = db.getCollection(Tasks)
#echo $$tasks

var t: Tasks
t.description = "Test task"
t.bits = 5
t.dir = east

echo $$t
let node = parseJson($$t)

var t1: Tasks
unpack(t1, node)
