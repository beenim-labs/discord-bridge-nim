## JSON pointer helpers compatible with the Go database/json.go intent.

type
  JsonBox*[T] = object
    data*: ref T

proc untypedNil*[T](val: ref T): ref T =
  if val.isNil:
    return nil
  val

proc jsonPtr*[T](val: ref T): JsonBox[T] =
  JsonBox[T](data: untypedNil(val))
