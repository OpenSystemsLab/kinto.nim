import httpclient, strutils, json

proc getStatusCode*(resp: Response): int =
  return parseInt(split(resp.status, ' ')[0])

proc `or`*(a, b: string): string {.inline, noSideEffect.} =
  if a.isNil or a == "":
    b
  else:
    a

proc `$`*(p: Proxy): string =
  $p.url


proc unpack*[T](target: var T, json: JsonNode) =
  for name, value in target.fieldPairs:
    if json.hasKey(name) and json[name].kind != JNull:
      echo name
      var node = json[name]
      when value is string:
        value = node.str
      elif value is int:
        value = node.num.int
      elif value is int8:
        value = node.num.int8
      elif value is int16:
        value = node.num.int16
      elif value is int32:
        value = node.num.int32
      elif value is int64:
        value = node.num.int64
      elif value is uint:
        value = node.num.uint
      elif value is uint8:
        value = node.num.uint8
      elif value is uint16:
        value = node.num.uint16
      elif value is uint32:
        value = node.num.uint32
      elif value is uint64:
        value = node.num.uint64
      elif value is float:
        value = node.fnum
      elif value is float32:
        value = node.fnum.float32
      elif value is float64:
        value = node.fnum.float64
      elif value is bool:
        value = node.bval
      elif value is char:
        if node.str.len > 0:
          value = node.str[0]
      elif value is object:
        unpack(value, node)
      elif value is array:
        #elems
        discard
      elif value is enum:
        echo "-----------", value
      else:
        if value != nil:
          raise newException(ValueError, "unsupported value: " & $value)
