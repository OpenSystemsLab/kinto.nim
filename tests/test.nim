import kinto

type
  Tasks = object of Collection
    description: string

var db = Kinto("http://ss.huy.im/v1", "kinto", "s3cret", "todo") #, proxy=("http://192.168.1.16:8888"))
#var todo = db.createBucket("todo")
#db.save(todo)
#db.use("todo")
#discard db.createCollection(Tasks)

var tasks = db.getCollection(Tasks)
echo tasks.description
#db.drop(todo)

#nimdoc.create()
#nimdoc.save()
#nimdoc.drop()
