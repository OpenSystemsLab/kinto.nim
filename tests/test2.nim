#import streams

type
  Writable[T] = concept s
    write(s, 'a')

proc write(s: var string, x: char) =
  s.add(x)


proc writeTest(w: var Writable, s: char) =
  discard

#var s = newStringStream()
var s: string
writeTest(s, 'a')
