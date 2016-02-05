import httpclient, strutils

proc getStatusCode*(resp: Response): int =
  return parseInt(split(resp.status, ' ')[0])
