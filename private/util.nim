import httpclient, strutils

proc getStatusCode*(resp: Response): int =
  return parseInt(split(resp.status, ' ')[0])

proc `or`*(a, b: string): string {.inline, noSideEffect.} =
  if a.isNil or a == "":
    b
  else:
    a

proc `$`*(p: Proxy): string =
  $p.url
