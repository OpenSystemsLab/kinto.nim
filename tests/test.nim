import ../kinto, marshal, ../private/util.nim

type
  Direction = enum
    north, east, south, west

type
  Todo = ref object of Collection
    description: string
    bits: uint32
    dir: Direction

  Task = ref object of Record
    title: string
    done: bool

var db = Kinto("http://ss.huy.im/v1", "kinto", "s3cret", "default") #, proxy=("http://192.168.1.16:8888"))

for c in db.getCollections():
  echo get[Todo](db, c.id).id

db.dropCollections()
#var todo: Todo
#todo.description = "Fuck yeah!"
#db.save(todo)

#var t1: Task
#t1.title = "Finish API"
#db.save(t1)
#echo get[Task](db, t1.id)
