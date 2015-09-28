# Some nice console support.

import buffertype, buffer, os, osproc, streams, strutils

type
  CmdHistory* = object
    cmds*: seq[string]
    suggested*: int

proc addCmd*(h: var CmdHistory; cmd: string) =
  var replaceWith = -1
  for i in 0..high(h.cmds):
    if h.cmds[i] == cmd:
      # suggest it again:
      h.suggested = i
      return
    elif h.cmds[i] in cmd:
      # correct previously wrong or shorter command:
      if replaceWith < 0 or h.cmds[replaceWith] < h.cmds[i]: replaceWith = i
  if replaceWith < 0:
    h.cmds.add cmd
  else:
    h.cmds[replaceWith] = cmd

proc suggest*(h: var CmdHistory; up: bool): string =
  if h.suggested < 0 or h.suggested >= h.cmds.len:
    h.suggested = (if up: h.cmds.high else: 0)
  if h.suggested >= 0 and h.suggested < h.cmds.len:
    result = h.cmds[h.suggested]
    h.suggested += (if up: -1 else: 1)
  else:
    result = ""

type
  Console* = ref object
    b: Buffer
    hist: CmdHistory
    files: seq[string]
    processRunning*: bool

proc insertReadonly*(c: Console; s: string) =
  c.b.readOnly = -2
  c.b.insert(s)
  c.b.readOnly = c.b.len-1

proc insertPrompt(c: Console) =
  c.insertReadOnly(os.getCurrentDir() & ">")

proc newConsole*(b: Buffer): Console =
  result = Console(b: b, hist: CmdHistory(cmds: @[], suggested: -1), files: @[])
  result.insertPrompt()

proc getCommand(c: Console): string =
  result = ""
  let b = c.b
  for i in b.readOnly+1 .. <c.b.len:
    result.add c.b[i]

proc emptyCmd(c: Console) =
  let b = c.b
  while true:
    if b.len-1 <= b.readOnly: break
    backspace(b)

proc upPressed*(c: Console) =
  let sug = c.hist.suggest(up=true)
  if sug.len > 0:
    emptyCmd(c)
    c.b.insert sug

proc downPressed*(c: Console) =
  let sug = c.hist.suggest(up=false)
  if sug.len > 0:
    emptyCmd(c)
    c.b.insert sug

proc handleHexChar(s: string; pos: int; xi: var int): int =
  case s[pos]
  of '0'..'9':
    xi = (xi shl 4) or (ord(s[pos]) - ord('0'))
    result = pos+1
  of 'a'..'f':
    xi = (xi shl 4) or (ord(s[pos]) - ord('a') + 10)
    result = pos+1
  of 'A'..'F':
    xi = (xi shl 4) or (ord(s[pos]) - ord('A') + 10)
    result = pos+1
  else: discard

proc parseEscape(s: string; w: var string; start=0): int =
  var pos = start+1 # skip '\'
  case s[pos]
  of 'n', 'N':
    w.add("\n")
    inc(pos)
  of 'r', 'R', 'c', 'C':
    add(w, '\c')
    inc(pos)
  of 'l', 'L':
    add(w, '\L')
    inc(pos)
  of 'f', 'F':
    add(w, '\f')
    inc(pos)
  of 'e', 'E':
    add(w, '\e')
    inc(pos)
  of 'a', 'A':
    add(w, '\a')
    inc(pos)
  of 'b', 'B':
    add(w, '\b')
    inc(pos)
  of 'v', 'V':
    add(w, '\v')
    inc(pos)
  of 't', 'T':
    add(w, '\t')
    inc(pos)
  of '\'', '\"':
    add(w, s[pos])
    inc(pos)
  of '\\':
    add(w, '\\')
    inc(pos)
  of 'x', 'X':
    inc(pos)
    var xi = 0
    pos = handleHexChar(s, pos, xi)
    pos = handleHexChar(s, pos, xi)
    add(w, chr(xi))
  of '0'..'9':
    var xi = 0
    while s[pos] in {'0'..'9'}:
      xi = (xi * 10) + (ord(s[pos]) - ord('0'))
      inc(pos)
    if xi <= 255: add(w, chr(xi))
  else:
    w.add('\\')
  result = pos

proc parseWord(s: string; w: var string;
               start=0; convToLower=false): int =
  template conv(c): untyped = (if convToLower: c.toLower else: c)
  w.setLen(0)
  var i = start
  while s[i] in {' ', '\t'}: inc i
  case s[i]
  of '\'':
    inc i
    while i < s.len:
      if s[i] == '\'':
        if s[i+1] == '\'':
          w.add s[i]
          inc i
        else:
          inc i
          break
      else:
        w.add s[i].conv
      inc i
  of '"':
    inc i
    while i < s.len:
      if s[i] == '"':
        inc i
        break
      elif s[i] == '\\':
        i = parseEscape(s, w, i)
      else:
        w.add s[i].conv
        inc i
  else:
    while s[i] > ' ':
      w.add s[i].conv
      inc i
  result = i

proc startsWithIgnoreCase(s, prefix: string): bool =
  var i = 0
  while true:
    if prefix[i] == '\0': return true
    if s[i].toLower != prefix[i].toLower: return false
    inc(i)

proc suggestPath(c: Console; prefix: string) =
  var sug = -1
  for i, x in c.files:
    if x.startsWithIgnoreCase(prefix):
      sug = i
      break
  if sug < 0 and prefix.len > 0:
    # if we have no prefix, pick a file that contains the prefix somewhere
    let p = prefix.toLower
    for i, x in c.files:
      if p in x.toLower:
        sug = i
        break
  # no match, just suggest something:
  if sug < 0: sug = 0
  for i in 0..<prefix.len: backspace(c.b, overrideUtf8=true)
  insert(c.b, c.files[sug])
  delete(c.files, sug)

proc tabPressed*(c: Console) =
  let cmd = getCommand(c)
  if c.files.len == 0:
    for k, x in os.walkDir(os.getCurrentDir(), relative=true):
      c.files.add x

  # suggest the path with the matching prefix (ignoring case),
  # but ultimately suggest every file:
  var a = ""
  var b = ""
  var i = 0
  while true:
    i = parseWord(cmd, b, i)
    # if b.len == 0 means at end:
    if b.len == 0:
      # parseWord always skips initial whitespace, so we look at the passed
      # character:
      if i > 0 and cmd[i-1] == ' ':
        suggestPath(c, "")
      else:
        suggestPath(c, a)
      break
    swap(a, b)

proc cmdToArgs(cmd: string): tuple[exe: string, args: seq[string]] =
  result.exe = ""
  result.args = @[]
  var i = parseWord(cmd, result.exe, 0)
  while true:
    var x = ""
    i = parseWord(cmd, x, i)
    if x.len == 0: break
    result.args.add x

# Threading channels
var requests: Channel[string]
requests.open()
var responses: Channel[string]
responses.open()
# Threading channels END

const EndToken = "\e" # a single ESC

proc execThreadProc() {.thread.} =
  template waitForExit() =
    started = false
    let exitCode = p.waitForExit()
    p.close()
    if exitCode != 0:
      responses.send("Process terminated with exitcode: " & $exitCode & "\L")
    responses.send EndToken
  template echod(msg) = echo msg

  var p: Process
  var o: Stream
  var started = false
  while true:
    var tasks = requests.peek()
    if tasks == 0 and not started: tasks = 1
    if tasks > 0:
      for i in 0..<tasks:
        let task = requests.recv()
        if task == EndToken:
          echod("[Thread] Stopping process.")
          p.terminate()
          o.close()
          waitForExit()
        else:
          if not started:
            let (bin, args) = cmdToArgs(task)
            started = true
            try:
              p = startProcess(bin, os.getCurrentDir(), args,
                               options = {poStdErrToStdOut, poUsePath})
            except:
              started = false
              responses.send getCurrentExceptionMsg()
              responses.send EndToken
            echod "STARTED " & bin
            o = p.outputStream
          else:
            echod("[Thread] Ignored request " & task)
    # Check if process exited.
    if started:
      if not p.running:
        echod("[Thread] Process exited.")
        while not o.atEnd:
          let line = o.readAll()
          responses.send(line)

        # Process exited.
        waitForExit()
      if osproc.hasData(p):
        let line = o.readAll()
        responses.send(line)

var backgroundThread: Thread[void]
createThread[void](backgroundThread, execThreadProc)

proc update*(c: Console) =
  if c.processRunning:
    if responses.peek > 0:
      let resp = responses.recv()
      if resp == EndToken:
        c.processRunning = false
        c.insertReadOnly "\L"
        insertPrompt(c)
      else:
        insertReadOnly(c, resp)

proc sendBreak*(c: Console) =
  if c.processRunning:
    requests.send EndToken

proc enterPressed*(c: Console) =
  c.files.setLen 0
  let cmd = getCommand(c)
  addCmd(c.hist, cmd)
  var a = ""
  var i = parseWord(cmd, a, 0, true)
  c.insertReadOnly "\L"
  case a
  of "":
    insertPrompt c
  of "cls":
    clear(c.b)
    insertPrompt c
  of "cd":
    var b = ""
    i = parseWord(cmd, b, i)
    try:
      os.setCurrentDir(b)
    except OSError:
      c.insertReadOnly(getCurrentExceptionMsg() & "\L")
    insertPrompt c
  else:
    requests.send cmd
    c.processRunning = true