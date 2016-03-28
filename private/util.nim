import httpclient, strutils, macros

proc getStatusCode*(resp: Response): int =
  return parseInt(split(resp.status, ' ')[0])

proc `or`*(a, b: string): string {.inline, noSideEffect.} =
  if a.isNil or a == "":
    b
  else:
    a

proc `$`*(p: Proxy): string =
  $p.url

template empty*(s: string): expr =
  s == nil or s == ""

proc getEndpoint*(kind: string, a, b, c = ""): string {.inline, noSideEffect.} =
  kind % [a, b, c]


proc nimNodeToString*(n: NimNode, topLevel = true): string {.compileTime.} =
  case n.kind
  of nnkStrLit:
    if not topLevel:
      result = "\"" & $n.strVal & "\""
    else:
      result = $n.strVal
  of nnkIntLit:
    result = $n.intVal
  of nnkBracket:
    result = ""
    var first = true
    for i in 0..n.len-1:
      if first:
        first = false
      else:
        result.add ","
      result.add nimNodeToString(n[i], false)
  else:
    raise newException(ValueError, "unsupported value: " & $n)
