import tables
const
  JSON_ZONE_SIZE = 4096
  JSON_STACK_SIZE = 32

discard """
    of '"':
      o = JsonNodeValue(kind: kString, pair: (next, toofar));
      discard = "
      for (char *it = s; *s; ++it, ++s) {
          int c = *it = *s;
          if (c == '\\') {
              c = *++s;
              switch (c) {
              case '\\':
              case '"':
              case '/':
                  *it = c;
                  break;
              case 'b':
                  *it = '\b';
                  break;
              case 'f':
                  *it = '\f';
                  break;
              case 'n':
                  *it = '\n';
                  break;
              case 'r':
                  *it = '\r';
                  break;
              case 't':
                  *it = '\t';
                  break;
              case 'u':
                  c = 0;
                  for (int i = 0; i < 4; ++i) {
                      if (isxdigit(*++s)) {
                          c = c * 16 + char2int(*s);
                      } else {
                          *endptr = s;
                          return JSON_BAD_STRING;
                      }
                  }
                  if (c < 0x80) {
                      *it = c;
                  } else if (c < 0x800) {
                      *it++ = 0xC0 | (c >> 6);
                      *it = 0x80 | (c & 0x3F);
                  } else {
                      *it++ = 0xE0 | (c >> 12);
                      *it++ = 0x80 | ((c >> 6) & 0x3F);
                      *it = 0x80 | (c & 0x3F);
                  }
                  break;
              default:
                  *endptr = s;
                  return JSON_BAD_STRING;
              }
          } else if ((unsigned int)c < ' ' || c == '\x7F') {
              *endptr = s;
              return JSON_BAD_STRING;
          } else if (c == '"') {
              *it = 0;
              ++s;
              break;
          }
      }
      if (not isdelim(*s)) {
          *endptr = s;
          return JSON_BAD_STRING;
      }
      break
      "
#include "gason.h"
#include <stdlib.h>

#define JSON_ZONE_SIZE 4096
#define JSON_STACK_SIZE 32

const char *jsonStrError(int err) {
    switch (err) {
#define XX(no, str) \
    case JSON_##no: \
        return str;
        JSON_ERRNO_MAP(XX)
#undef XX
    default:
        return "unknown";
    }
}

void *JsonAllocator::allocate(size_t size) {
    size = (size + 7) & ~7;

    if (head && head->used + size <= JSON_ZONE_SIZE) {
        char *p = (char *)head + head->used;
        head->used += size;
        return p;
    }

    size_t allocSize = sizeof(Zone) + size;
    Zone *zone = (Zone *)malloc(allocSize <= JSON_ZONE_SIZE ? JSON_ZONE_SIZE : allocSize);
    zone->used = allocSize;
    if (allocSize <= JSON_ZONE_SIZE || head == nullptr) {
        zone->next = head;
        head = zone;
    } else {
        zone->next = head->next;
        head->next = zone;
    }
    return (char *)zone + sizeof(Zone);
}

void JsonAllocator::deallocate() {
    while (head) {
        Zone *next = head->next;
        free(head);
        head = next;
    }
}

static inline bool isspace(char c) {
    return c == ' ' || (c >= '\t' && c <= '\r');
}

static inline bool isdelim(char c) {
    return c == ',' || c == ':' || c == ']' || c == '}' || isspace(c) || !c;
}

static inline bool isdigit(char c) {
    return c >= '0' && c <= '9';
}

static inline bool isxdigit(char c) {
    return (c >= '0' && c <= '9') || ((c & ~' ') >= 'A' && (c & ~' ') <= 'F');
}

static inline int char2int(char c) {
    if (c <= '9')
        return c - '0';
    return (c & ~' ') - 'A' + 10;
}

static double string2double(char *s, char **endptr) {
    char ch = *s;
    if (ch == '-')
        ++s;

    double result = 0;
    while (isdigit(*s))
        result = (result * 10) + (*s++ - '0');

    if (*s == '.') {
        ++s;

        double fraction = 1;
        while (isdigit(*s)) {
            fraction *= 0.1;
            result += (*s++ - '0') * fraction;
        }
    }

    if (*s == 'e' || *s == 'E') {
        ++s;

        double base = 10;
        if (*s == '+')
            ++s;
        else if (*s == '-') {
            ++s;
            base = 0.1;
        }

        int exponent = 0;
        while (isdigit(*s))
            exponent = (exponent * 10) + (*s++ - '0');

        double power = 1;
        for (; exponent; exponent >>= 1, base *= base)
            if (exponent & 1)
                power *= base;

        result *= power;
    }

    *endptr = s;
    return ch == '-' ? -result : result;
}

static inline JsonNode *insertAfter(JsonNode *tail, JsonNode *node) {
    if (!tail)
        return node->next = node;
    node->next = tail->next;
    tail->next = node;
    return node;
}

static inline JsonValue listToValue(JsonTag tag, JsonNode *tail) {
    if (tail) {
        auto head = tail->next;
        tail->next = nullptr;
        return JsonValue(tag, head);
    }
    return JsonValue(tag, nullptr);
}

int jsonParse(char *s, char **endptr, JsonValue *value, JsonAllocator &allocator) {
    JsonNode *tails[JSON_STACK_SIZE];
    JsonTag tags[JSON_STACK_SIZE];
    char *keys[JSON_STACK_SIZE];
    JsonValue o;
    int pos = -1;
    bool separator = true;
    *endptr = s;

    while (*s) {
        while (isspace(*s))
            ++s;
        *endptr = s++;
        switch (**endptr) {
        case '-':
            if (!isdigit(*s) && *s != '.') {
                *endptr = s;
                return JSON_BAD_NUMBER;
            }
        case '0':
        case '1':
        case '2':
        case '3':
        case '4':
        case '5':
        case '6':
        case '7':
        case '8':
        case '9':
            o = JsonValue(string2double(*endptr, &s));
            if (!isdelim(*s)) {
                *endptr = s;
                return JSON_BAD_NUMBER;
            }
            break;
        case '"':
            o = JsonValue(JSON_STRING, s);
            for (char *it = s; *s; ++it, ++s) {
                int c = *it = *s;
                if (c == '\\') {
                    c = *++s;
                    switch (c) {
                    case '\\':
                    case '"':
                    case '/':
                        *it = c;
                        break;
                    case 'b':
                        *it = '\b';
                        break;
                    case 'f':
                        *it = '\f';
                        break;
                    case 'n':
                        *it = '\n';
                        break;
                    case 'r':
                        *it = '\r';
                        break;
                    case 't':
                        *it = '\t';
                        break;
                    case 'u':
                        c = 0;
                        for (int i = 0; i < 4; ++i) {
                            if (isxdigit(*++s)) {
                                c = c * 16 + char2int(*s);
                            } else {
                                *endptr = s;
                                return JSON_BAD_STRING;
                            }
                        }
                        if (c < 0x80) {
                            *it = c;
                        } else if (c < 0x800) {
                            *it++ = 0xC0 | (c >> 6);
                            *it = 0x80 | (c & 0x3F);
                        } else {
                            *it++ = 0xE0 | (c >> 12);
                            *it++ = 0x80 | ((c >> 6) & 0x3F);
                            *it = 0x80 | (c & 0x3F);
                        }
                        break;
                    default:
                        *endptr = s;
                        return JSON_BAD_STRING;
                    }
                } else if ((unsigned int)c < ' ' || c == '\x7F') {
                    *endptr = s;
                    return JSON_BAD_STRING;
                } else if (c == '"') {
                    *it = 0;
                    ++s;
                    break;
                }
            }
            if (!isdelim(*s)) {
                *endptr = s;
                return JSON_BAD_STRING;
            }
            break;
        case 't':
            if (!(s[0] == 'r' && s[1] == 'u' && s[2] == 'e' && isdelim(s[3])))
                return JSON_BAD_IDENTIFIER;
            o = JsonValue(JSON_TRUE);
            s += 3;
            break;
        case 'f':
            if (!(s[0] == 'a' && s[1] == 'l' && s[2] == 's' && s[3] == 'e' && isdelim(s[4])))
                return JSON_BAD_IDENTIFIER;
            o = JsonValue(JSON_FALSE);
            s += 4;
            break;
        case 'n':
            if (!(s[0] == 'u' && s[1] == 'l' && s[2] == 'l' && isdelim(s[3])))
                return JSON_BAD_IDENTIFIER;
            o = JsonValue(JSON_NULL);
            s += 3;
            break;
        case ']':
            if (pos == -1)
                return JSON_STACK_UNDERFLOW;
            if (tags[pos] != JSON_ARRAY)
                return JSON_MISMATCH_BRACKET;
            o = listToValue(JSON_ARRAY, tails[pos--]);
            break;
        case '}':
            if (pos == -1)
                return JSON_STACK_UNDERFLOW;
            if (tags[pos] != JSON_OBJECT)
                return JSON_MISMATCH_BRACKET;
            if (keys[pos] != nullptr)
                return JSON_UNEXPECTED_CHARACTER;
            o = listToValue(JSON_OBJECT, tails[pos--]);
            break;
        case '[':
            if (++pos == JSON_STACK_SIZE)
                return JSON_STACK_OVERFLOW;
            tails[pos] = nullptr;
            tags[pos] = JSON_ARRAY;
            keys[pos] = nullptr;
            separator = true;
            continue;
        case '{':
            if (++pos == JSON_STACK_SIZE)
                return JSON_STACK_OVERFLOW;
            tails[pos] = nullptr;
            tags[pos] = JSON_OBJECT;
            keys[pos] = nullptr;
            separator = true;
            continue;
        case ':':
            if (separator || keys[pos] == nullptr)
                return JSON_UNEXPECTED_CHARACTER;
            separator = true;
            continue;
        case ',':
            if (separator || keys[pos] != nullptr)
                return JSON_UNEXPECTED_CHARACTER;
            separator = true;
            continue;
        case '\0':
            continue;
        default:
            return JSON_UNEXPECTED_CHARACTER;
        }

        separator = false;

        if (pos == -1) {
            *endptr = s;
            *value = o;
            return JSON_OK;
        }

        if (tags[pos] == JSON_OBJECT) {
            if (!keys[pos]) {
                if (o.getTag() != JSON_STRING)
                    return JSON_UNQUOTED_KEY;
                keys[pos] = o.toString();
                continue;
            }
            tails[pos] = insertAfter(tails[pos], (JsonNode *)allocator.allocate(sizeof(JsonNode)));
            tails[pos]->key = keys[pos];
            keys[pos] = nullptr;
        } else {
            tails[pos] = insertAfter(tails[pos], (JsonNode *)allocator.allocate(sizeof(JsonNode) - sizeof(char *)));
        }
        tails[pos]->value = o;
    }
    return JSON_BREAKING_BAD;
}
"""
type
  CArray{.unchecked.}[T] = array[0..0, T]
  # CArray{.unchecked.}[T] = array[0..0, T]
  Data = CArray[char]
  ErrNo = enum
    JSON_OK,
    JSON_BAD_NUMBER, JSON_BAD_STRING, JSON_BAD_IDENTIFIER,
    JSON_STACK_OVERFLOW, JSON_STACK_UNDERFLOW,
    JSON_MISMATCH_BRACKET, JSON_UNEXPECTED_CHARACTER, JSON_UNQUOTED_KEY,
    JSON_BREAKING_BAD
  ErrNoEnd = tuple[errno: ErrNo, unused: int32]
  JsonTag = enum
    JSON_NUMBER,
    JSON_STRING,
    JSON_ARRAY,
    JSON_OBJECT,
    JSON_TRUE,
    JSON_FALSE,
    JSON_NULL,
  JsonValueKind = enum
    kString, kHash, kArray, kNil
  IntPair = tuple[sbeg: int32, send: int32]
  JsonValue = ref JsonValueObj
  JsonValueObj {.acyclic.} = object
    case kind: JsonValueKind
    of kString:
      vString: string
    of kHash:
      vHash: tables.Table[string, JsonValue]
    of kArray:
      vArray: seq[JsonValue]
    of kNil:
      nil
  JsonNodeValue = object
    case kind: JsonValueKind
    of kString:
      pair: IntPair
    of kHash:
      vHash: ptr JsonKeyNode
    of kArray:
      vArray: ptr JsonNode
    else:
      nil
  JsonNode = object
    value: JsonNodeValue
    next: ptr JsonNode
  JsonKeyNode = object
    value: JsonNodeValue
    next: ptr JsonKeyNode
    key: IntPair
var
  aPhony: JsonNode
  bPhony: JsonKeyNode
const phony = false
proc allocNode(): ptr JsonNode {.inline.} =
  when phony:
    return addr aPhony
  else:
    cast[ptr JsonNode](alloc(sizeof(JsonNode)))
proc allocKeyNode(): ptr JsonNode {.inline.} =
  when phony:
    return cast[ptr JsonNode](addr bPhony)
  else:
    cast[ptr JsonNode](alloc(sizeof(JsonKeyNode)))

proc getKind(me: JsonNodeValue): JsonValueKind =
  return me.kind
proc toString(me: JsonNodeValue): IntPair =
  assert(me.getKind() == kString);
  return me.pair
proc isspace(c: char): bool {.inline.} =
  return c == ' ' or (c >= '\t' and c <= '\r');
proc isdelim(c: char): bool {.inline.} =
  return c == ',' or c == ':' or c == ']' or c == '}' or isspace(c) or c == '\0';
proc isdigit(c: char): bool {.inline.} =
  return c >= '0' and c <= '9';
proc isxdigit(c: int8): bool {.inline.} =
  return (c >= cast[int8]('0') and c <= cast[int8]('9')) or ((c and not cast[int8](' ')) >= cast[int8]('A') and (c and not cast[int8](' ')) <= cast[int8]('F'));
proc char2int(c: int8): int {.inline.} =
  if c <= cast[int8]('9'):
    return cast[int8](c) - cast[int8]('0');
  return (c and not cast[int8](' ')) - cast[int8]('A') + 10;
proc nondelim(full: cstring, sbeg: int32, send: int32): IntPair {.inline.} =
  var i = sbeg
  while not isdelim(full[i]):
    inc i
  return (sbeg, i)
proc number(full: cstring, sbeg: int32, send: int32): IntPair =
  var i = sbeg
  if full[i] == '-':
    inc i
  while isdigit(full[i]):
    inc i
  if full[i] == '.':
    inc i
    while isdigit(full[i]):
      inc i
  if full[i] == 'e' or full[i] == 'E':
    inc i
    if full[i] == '+' or full[i] == '-':
      inc i
    while isdigit(full[i]):
      inc i
  return (sbeg, i)

#proc insertAfter(tail: ptr JsonNode, node: ptr JsonNode): ptr JsonNode {.inline.} =
proc insertAfter(tail: ptr JsonNode, node: ptr JsonNode): ptr JsonNode {.inline.} =
  if tail == nil:
    node.next = node
  else:
    node.next = tail.next
    tail.next = node
  return node
proc listToNode(tail: ptr JsonNode): ptr JsonNode {.inline.} =
  if tail != nil:
    let head = tail.next
    tail.next = nil
    return head
  return nil

proc jsonParse(full: cstring, size: int32): ErrNoEnd =
  result.unused = 0
  var next: int32 = 0
  #echo("next:" & full[next])
  let toofar: int32 = next + size
  var total = 0'i64
  #JsonNode *tails[JSON_STACK_SIZE];
  var tails: array[0.. <JSON_STACK_SIZE, ptr JsonNode];
  var tags: array[0.. <JSON_STACK_SIZE, JsonTag]
  var keys: array[0.. <JSON_STACK_SIZE, IntPair];
  let defaultkey: IntPair = (sbeg: 0'i32, send: 0'i32)
  var o: JsonNodeValue
  var pos = -1;
  var separator: bool = true
  while next < toofar:
    if isspace(full[next]):
      total += 1
      inc next
      continue
    result.unused = next
    #echo("read:" & full[result.unused])
    inc next
    case full[result.unused]:
    of '-', '0' .. '9':
      #echo("after #:" & full[next])
      let p = nondelim(full, result.unused, next)
      #echo("p:" & $p)
      o = JsonNodeValue(kind: kString, pair: p)
      next = p.send
      if not isdelim(full[next]):
        result.unused = next
        result.errno = JSON_BAD_NUMBER
        return
    of '"':
      #echo("after \":" & full[next])
      o = JsonNodeValue(kind: kString, pair: (next, toofar))
      while next < toofar:
        var c = full[next]
        inc next
        if c == '"':
          o.pair.send = next
          break
        if c == '\\':
          # Skip escaped char(s).
          if next < toofar and full[next] == 'u':
            inc(next, 4)
          else:
            inc next
      #echo("next=" & $next & ", toofar=" & $toofar)
      if next >= toofar:
        result.unused = toofar
        result.errno = JSON_BAD_STRING
        return
      if not isdelim(full[next]):
        result.unused = next
        result.errno = JSON_BAD_STRING
        return
      #echo("finished str")
    of 't':
      if (not(full[next+0] == 'r' and full[next+1] == 'u' and full[next+2] == 'e' and isdelim(full[next+3]))):
        result.errno = JSON_BAD_IDENTIFIER
        return
      o = JsonNodeValue(kind: kString, pair: (next-1, next+3));
      next += 3;
    of 'f':
      if (not(full[next+0] == 'a' and full[next+1] == 'l' and full[next+2] == 's' and full[next+3] == 'e' and isdelim(full[next+4]))):
        result.errno = JSON_BAD_IDENTIFIER
        return
      o = JsonNodeValue(kind: kString, pair: (next-1, next+4));
      next += 4;
    of 'n':
      if (not(full[next] == 'u' and full[next+1] == 'l' and full[next+2] == 'l' and isdelim(full[next+3]))):
        result.errno = JSON_BAD_IDENTIFIER
        return
      o = JsonNodeValue(kind: kString, pair: (next-1, next+3));
      next += 3;
    of ']':
      #echo "Found ]"
      if (pos == -1):
        result.errno = JSON_STACK_UNDERFLOW
        return
      if (tags[pos] != JSON_ARRAY):
        result.errno = JSON_MISMATCH_BRACKET
        return
      let node = listToNode(tails[pos])
      o = JsonNodeValue(kind: kArray, vArray: node)
      dec pos
    of '}':
      #echo "Found }"
      if (pos == -1):
        result.errno = JSON_STACK_UNDERFLOW
        return
      if (tags[pos] != JSON_OBJECT):
        result.errno = JSON_MISMATCH_BRACKET
        return
      if (keys[pos] != defaultkey):
        #echo("unexpected }")
        result.errno = JSON_UNEXPECTED_CHARACTER
        return
      let node = cast[ptr JsonKeyNode](listToNode(tails[pos]))
      o = JsonNodeValue(kind: kHash, vHash: node)
      dec pos
    of '[':
      #echo "Found ["
      inc pos
      if (pos == JSON_STACK_SIZE):
        result.errno = JSON_STACK_OVERFLOW
        return
      tails[pos] = nil
      tags[pos] = JSON_ARRAY
      keys[pos] = defaultkey
      separator = true
      continue
    of '{':
      #echo "Found {"
      inc pos
      if (pos == JSON_STACK_SIZE):
        result.errno = JSON_STACK_OVERFLOW
        return
      tails[pos] = nil
      tags[pos] = JSON_OBJECT
      keys[pos] = defaultkey
      separator = true
      continue;
    of ':':
      if (separator or keys[pos] == defaultkey):
        #echo("unexpected :")
        result.errno = JSON_UNEXPECTED_CHARACTER
        return
      separator = true
      continue
    of ',':
      if (separator or keys[pos] != defaultkey):
        #echo("unexpected ," & $keys[pos] & full[keys[pos].sbeg])
        #echo("tag:" & $tags[pos])
        result.errno = JSON_UNEXPECTED_CHARACTER
        return
      separator = true
      continue
    of '\0':
      continue
    else:
      echo("unexpected char:" & full[next-1])
      result.errno = JSON_UNEXPECTED_CHARACTER
      return
    separator = false;
    #echo("bottom of while")
    if pos == -1:
      result.unused = next
      result.errno = JSON_OK
      echo("totalws=" & $total)
      #*value = o;
      return
    if tags[pos] == JSON_OBJECT:
      #echo("OBJECT")
      if keys[pos].send == 0:
        #echo("No end in sight.")
        if o.getKind() != kString:
          #echo("Not a str!")
          result.errno = JSON_UNQUOTED_KEY
          return
        keys[pos] = o.toString();
        continue
      tails[pos] = insertAfter(tails[pos], allocKeyNode())
      cast[ptr JsonKeyNode](tails[pos]).key = keys[pos];
      keys[pos] = defaultkey
    else:
      #echo("ARRAY?")
      tails[pos] = insertAfter(tails[pos], allocNode())
    tails[pos].value = o
    #echo("assigned o to value")
  result.errno = JSON_BREAKING_BAD
  return
proc Sum(b: ptr char, size: int32): int64 =
  var s = cast[cstring](b)
  var i = 0'i32
  var total = 0'i64
  echo("size=" & $size)
  while i < size:
    #echo(b[i])
    total += cast[int](s[i])
    inc i
  echo("last=" & $(s[i]))
  echo("total=" & $total)
  return total
proc nim_jsonParse*(b: ptr char, size: int32, e: ptr ptr char, val: ptr cint): cint
  {.cdecl, exportc, dynlib.} =
  #discard Sum(b, size)
  let full: cstring = cast[cstring](b)
  var res = jsonParse(full, size)
  echo("res=" & $res)
proc test() =
  echo "hi"
when isMainModule:
  test()
