# Nimview UI Library 
# Copyright (C) 2021, by Marco Mengelkoch
# Licensed under MIT License, see License file for more details
# git clone https://github.com/marcomq/nimview

# import logging, tables, json, os

# when not defined(just_core):
#   import nimpy
#   from nimpy/py_types import PPyObject
# else:
#   macro exportpy(def: untyped): untyped =
#     result = def

type ReqFunction* = object
  nimCallback: proc (values: JsonNode): string
  jsSignature: string

var reqMap* {.threadVar.}: Table[string, ReqFunction] 

var requestLogger* {.threadVar.}: FileLogger

proc parseAny[T](value: string): T =
  when T is string:
    result = value
  elif T is JsonNode:
    result = json.parseJsonvalue(value)
  elif T is bool:
    result = strUtils.parseBool(value)
  elif T is enum:
    result = strUtils.parseEnum(value)
  elif T is uint:
    result = strUtils.parseUInt(value)
  elif T is int:
    result = strUtils.parseInt(value)
  elif T is float:
    result = strUtils.parseFloat(value)
  # when T is array:
  #   result = strUtils.parseEnum(value)

template withStringFailover[T](value: JsonNode, jsonType: JsonNodeKind, body: untyped) =
    if value.kind == jsonType:
      body
    elif value.kind == JString:
      result = parseAny[T](value.getStr())
    else: 
      result = parseAny[T]($value)

proc parseAny[T](value: JsonNode): T =
  when T is JsonNode:
    result = value
  elif T is (int or uint):
    withStringFailover[T](value, Jint):
      result = value.getInt()
  elif T is float:
    withStringFailover[T](value, JFloat):
      result = value.getFloat()
  elif T is bool:
    withStringFailover[T](value, JBool):
      result = value.getBool()
  elif T is string:
    if value.kind == JString:
      result = value.getStr()
    else: 
      result = parseAny[T]($value)
  elif T is varargs[string]:
    if (value.kind == JArray):
      newSeq(result, value.len)
      for i in value.len:
        result[i] = parseAny[string](value[i])
    else:
      result = value.to(T)
  else: 
    result = value.to(T)

proc addRequest*(request: string, callback: proc(values: JsonNode): string, jsSignature = "value") =
  {.gcsafe.}: 
    reqMap[request] = ReqFunction(nimCallback: callback, jsSignature: jsSignature)

proc addRequest*[T](request: string, callback: proc(value: T): string) =
    addRequest(request, proc (values: JsonNode): string =
      result = callback(parseAny[T](values)), 
      "value")
      
proc addRequest*[T](request: string, callback: proc(value: T)) =
    addRequest(request, proc (values: JsonNode): string =
      callback(parseAny[T](values)), 
      "value")

template runWithBody(minLength: int, body: untyped) =
  proc localFunc(values {.inject.}: JsonNode): string =
    if values.len >= minLength:
      body
    else:
      raise newException(ServerException, "Called request '" & request & "' contains less than " & $minLength & " arguments")
  var jsonValues = ""
  for i in 0 ..< minLength:
    jsonValues &= (if i != 0: ", " else: "") & "value" & $i
  addRequest(request, localFunc, jsonValues)
  
# proc addRequest*[T1, T2, R](request: string, callback: proc(value1: T1, value2: T2): R) =
#   runWithBody(2):
#      callback(parseAny[T1](values[0]), parseAny[T2](values[1]))

proc addRequest*[T1, T2, R](request: string, callback: proc(value1: T1, value2: T2): R) =
    addRequest(request, proc (values: JsonNode): string = 
      if values.len > 2:
        callback(parseAny[T1](values[0]), parseAny[T2](values[1]))
      else:
        raise newException(ServerException, "Called request '" & request & "' contains less than 3 arguments"),
      "value1, value2")

proc addRequest*[T1, T2, T3](request: string, callback: proc(value1: T1, value2: T2, value3: T3): string) =
    addRequest(request, proc (values: JsonNode): string = 
      if values.len > 2:
        result = callback(parseAny[T1](values[0]), parseAny[T2](values[1]), parseAny[T3](values[3]))
      else:
        raise newException(ServerException, "Called request '" & request & "' contains less than 3 arguments"),
      "value1, value2, value3")

proc addRequest*(request: string, callback: proc(): string) =
    addRequest(request, proc (values: JsonNode): string = callback(), "")

# proc addRequest*(request: string, callback: proc(): string|void) =
#    addRequest(request, proc (values: JsonNode): string = callback(), "")

proc addRequest*(request: string, callback: proc(value: string): string {.gcsafe.}) =
  ## This will register a function "callback" that can run on back-end.
  ## "addRequest" will be performed with "value" each time the javascript client calls:
  ## `window.ui.backend(request, value, function(response) {...})`
  ## with the specific "request" value.
  ## There are also overloaded functions for less or additional parameters
  ## There is a wrapper for python, C and C++ to handle strings in each specific programming language
  ## Notice for python: There is no check for correct function signature!
  addRequest[string](request, callback)
  
proc addRequest*(request: string, callback: proc(value: string) {.gcsafe.}) =
  addRequest[string](request, callback)

proc getCallbackFunc*(request: string): proc(values: JsonNode): string =
  reqMap.withValue(request, callbackFunc) do: # if request available, run request callbackFunc
    try:
      result = callbackFunc[].nimCallback
    except:
      raise newException(ServerException, "Server error calling request '" & 
        request & "': " & getCurrentExceptionMsg())
  do:
    raise newException(ReqUnknownException, "404 - Request unknown")