import ../kinto, marshal, ../private/util.nim

type
  Direction = enum
    north, east, south, west

type
  Todo = object of Collection
    description: string
    bits: uint32
    dir: Direction

  Task = object of Record
    title: string
    done: bool




var db = Kinto("http://ss.huy.im/v1", "kinto", "s3cret", "todo") #, proxy=("http://192.168.1.16:8888"))

var todo: Todo
todo.description = "Fuck yeah!"
db.save(todo)

echo get[Task](db, "1")
