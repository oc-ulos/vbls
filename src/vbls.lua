--!lua
-----------------------------------
-- The Vaguely Bourne-Like Shell --
--   by the ULOS 2 Developers    --
-----------------------------------
--
-- This shell should work both on Linux and on ULOS 2.

local _VBLS_VERSION = "1.0.0"

local argv = {...}

local fork
local unistd = require("posix.unistd")

-- this is how we detect running under ULOS 2.
-- Mostly used to select which fork() to use.
if type(argv[1]) == "table" then
  argv = argv[1]
  fork = require("syscalls").fork
else
  argv[0] = "vbls"
  local _fork = unistd.fork
  fork = function(func)
    local pid, _, _errno = _fork()
    if not pid then
      return nil, _errno
    end

    if pid == 0 then
      func()
    else
      return pid
    end
  end
end

local wait = require("posix.sys.wait").wait
local errno = require("posix.errno")
local stdio = require("posix.stdio")
local stdlib = require("posix.stdlib")
local readline = require("readline")

local args, opts = require("getopt").getopt({
  options = {
    h = false, help = false,
    c = true, login = false,
    e = false, x = false,
  },
  allow_finish = true,
  exit_on_bad_opt = true,
  help_message = argv[0] .. ": pass '--help' for usage information\n"
}, argv)

local defaultPath = "/bin:/sbin:/usr/bin"

local commandPaths = {}
local shopts = {
  cachepaths = true,
  errexit = false,
  showcommands = false
}

-- some default environment setup
stdlib.setenv("0", argv[0])
for i=1, #args, 1 do
  stdlib.setenv(tostring(i), tostring(args[i]))
end
stdlib.setenv("VBLS_VERSION", _VBLS_VERSION)
stdlib.setenv("HOME", os.getenv("HOME") or "/")
stdlib.setenv("SHLVL",
  tostring(math.floor(tonumber(os.getenv("SHLVL") or 0) + 1)))

-- builtins
local function writeError(err, ...)
  io.stdout:flush()
  if type(err) == "number" then err = errno.errno(err) end
  io.stderr:write("vbls: ", string.format(err, ...), "\n")
  io.stderr:flush()
end

local builtins = {}

function builtins.printf(argt, input, output)
  if #argt == 0 then
    writeError("usage: printf format [arguments]")
    return 1
  end
  local ok, err = pcall(string.format, table.unpack(argt))
  if ok then
    builtins.echo({err}, input, output)
  else
    writeError("printf: %s", err)
    return 1
  end
  return 0
end

function builtins.echo(argt, _, output)
  output = output or 1
  local outstr = ""
  for i=1, #argt, 1 do
    outstr = outstr .. tostring(argt[i])
    if i < #argt then outstr = outstr .. " " end
  end
  unistd.write(output, outstr.."\n")
  return 0
end

function builtins.cd(argt)
  local to

  if #argt == 0 then
    if not os.getenv("HOME") then
      writeError("cd: HOME not set")
      return 1

    else
      to = os.getenv("HOME") or "/"
    end

  elseif #argt > 1 then
    writeError("cd: too many arguments")
    return 1

  elseif argt[1] == "-" then
    if not os.getenv("OLDPWD") then
      writeError("cd: OLDPWD not set")
      return 1

    else
      to = os.getenv("OLDPWD")
    end

  else
    to = argt[1]
  end

  local eno
  to, eno = stdlib.realpath(to)

  if not to then
    writeError("cd: %s: %s", to, eno)
  end

  local oldwd = unistd.getcwd()
  local ok, err = unistd.chdir(to)
  if not ok then
    writeError("cd: %s: %s", to, err)
    return 1
  end

  stdlib.setenv("OLDPWD", oldwd)
  stdlib.setenv("PWD", to)

  return 0
end

local function subFindCommand(path, name)
  local test1 = stdlib.realpath(path .. "/" .. name)
  local test2 = stdlib.realpath(path .. "/" .. name .. ".lua")

  if test1 then
    return test1
  elseif test2 then
    return test2
  else
    return nil
  end
end

local function findCommand(name)
  local path = os.getenv("PATH") or defaultPath
  if builtins[name] then return true end
  if shopts.cachepaths and commandPaths[name] then
    return commandPaths[name] end

  if name:find("/", nil, true) then
    return name
  end

  for search in path:gmatch("[^:]+") do
    local cpath = subFindCommand(search, name)
    if cpath then
      if shopts.cachepath then commandPaths[name] = cpath end
      return cpath
    end
  end

  return nil, name .. ": command not found"
end

local whitespace = { [" "] = true, ["\n"] = true, ["\t"] = true }
local escapes = {
  ["\\"] = "\\",
  n = "\n",
  t = "\t",
  e = "\27",
  a = "\a",
}

-- VBLS follows the same quoting rules as Plan 9's rc:
--  'this is a valid quoted string'
--  'you're wrong if you think this is'
--  'but you''re correct if you think this is'
--  "and this isn't"
local function tokenize(chunk)
  local tokens = {""}
  local in_string = false
  local prev_char

  for c in chunk:gmatch(".") do
    if in_string then
      if prev_char == "\\" then
        if escapes[c] then
          tokens[#tokens] = tokens[#tokens] .. escapes[c]
          c = "ESCAPED"
        else
          return nil, "bad escape '"..c.."'"
        end

      elseif c == "'" then
        in_string = false

      elseif c ~= "\\" then
        tokens[#tokens] = tokens[#tokens] .. c
      end

    else

      if whitespace[c] then
        if #tokens[#tokens] > 0 then
          tokens[#tokens+1] = ""
        end

      elseif c == "'" then
        in_string = true
        if prev_char == c then
          tokens[#tokens] = tokens[#tokens] .. c
        end

      elseif c == ";" or c == "\n" then
        if #tokens[#tokens] > 0 then
          tokens[#tokens+1] = "SPLIT"..c.."SPLIT"

        else
          tokens[#tokens] = c
        end

        tokens[#tokens+1] = ""

      elseif c ~= "\\" then
        tokens[#tokens] = tokens[#tokens] .. c
      end
    end

    prev_char = c
  end

  if in_string then
    return nil, "unfinished string near '"..tokens[#tokens].."'"
  end

  if #tokens[#tokens] == 0 and prev_char ~= "'" then
    tokens[#tokens] = nil
  end

  return tokens
end

local function unexpected(token, near)
  if near then
    return string.format("unexpected '%s' near '%s'", token, near)
  else
    return string.format("unexpected '%s'", token)
  end
end

local increase = {["if"] = true, ["for"] = true, ["while"] = true}
local decrease = {["end"] = true}

local function seekBalanced(tokens, i, ...)
  local seekTo, __seekTo = {}, {...}
  for _, v in pairs(__seekTo) do
    seekTo[v] = true
  end

  local passed = {}

  local level = 1
  repeat
    local _token = tokens[i]
    i = i + 1
    if increase[_token] then
      level = level + 1
    elseif decrease[_token] then
      level = level - 1
    end
    if not seekTo[_token] then passed[#passed+1] = _token end
  until (seekTo[_token] and level <= 1) or not _token

  if level > 1 then
    return nil, "unbalanced block"
  end

  return i, passed
end

local function readTo(tokens, i, tok)
  local result = {}

  repeat
    local _token = tokens[i]
    if _token ~= tok then result[#result+1] = _token end
    i = i + 1
  until _token == tok or not _token

  return i, result
end

-- backgrounding with & is not yet supported; no job control
local separatorOperators = { ["|"] = true, ["||"] = true,
  ["&&"] = true }

-- Takes a single command and evaluates it.  If `input` or `output` is set,
-- the command's standard input or output will automatically redirect to
-- the file descriptors to which they point.
local function evaluateCommand(command)
  for i=1, #command, 1 do
    command[i] = command[i]:gsub("%$(%b{})", function(v)
      return os.getenv((v:sub(2,-2))) or ""
    end):gsub("%$([%w_]+)", function(v)
      return os.getenv(v) or ""
    end)
  end

  local path, err = findCommand(command[1])
  if not path then return nil, err end

  local argt = {table.unpack(command, 2)}
  argt[0] = command[1]

  if builtins[argt[0]] then
    return builtins[argt[0]](argt, command.input, command.output)
  else
    local pid = fork(function()
      if command.input then
        assert(unistd.dup2(command.input, 0))
        --unistd.close(command.input)
      end
      if command.output then
        assert(unistd.dup2(command.output, 1))
        --unistd.close(command.output)
      end

      local _, _err, _errno = unistd.exec(path, argt)
      io.stderr:write(("vbls: %s: %s\n"):format(path, _err))
      os.exit(_errno)
    end)

    if command.input then unistd.close(command.input) end

    local _, _, status = wait(pid)
    return status
  end
end

-- Take a command chain, e.g 'a && b || c', and process it.
local function evaluateCommandChain(tokens, flags)
  local commands = {{}}

  for i=1, #tokens, 1 do
    if separatorOperators[tokens[i]] then
      if #commands[#commands] == 0 then
        return nil, unexpected(tokens[i], tokens[i-1])
      end

      commands[#commands+1] = tokens[i]
      commands[#commands+1] = {}

    else
      table.insert(commands[#commands], tokens[i])
    end
  end

  if type(commands[#commands]) ~= "table" or #commands[#commands] == 0 then
    return nil, "expected command near <eof>"
  end

  local finalOutput, finalInput

  if flags and flags.output then
    finalOutput, finalInput = unistd.pipe()
    commands[#commands].output = finalInput
  end

  local i = 1
  local last_result = 0
  while commands[i] do
    local cmd = commands[i]
    local prog_out, prog_in = unistd.pipe()
    i = i + 1

    local operator = commands[i]
    if operator == "|" then
      cmd.output = prog_in
      commands[i+1].input = prog_out
    end

    local result, err = evaluateCommand(cmd)
    unistd.close(prog_in)

    if operator ~= "|" then unistd.close(prog_out) end
    if not result then
      if finalInput then unistd.close(finalInput) end
      if finalOutput then unistd.close(finalOutput) end
      return nil, err
    else
      last_result = result
    end
    i = i + 1
  end

  if flags and flags.output then
    unistd.close(finalInput)
    local output = ""
    repeat
      local chunk = unistd.read(finalOutput, 2048)
      output = output .. (chunk or "")
    until #chunk == 0 or not chunk
    unistd.close(finalOutput)
    return last_result, output
  end

  return last_result
end

-- Takes a set of tokens and evaluates them.  This is where things like
-- flow control happen.
local function evaluateTokens(tokens)
  local i = 1
  local currentCommand = {}

  while tokens[i] do
    local token = tokens[i]

    if token == "if" or token == "elseif" then
      local command
      i, command = readTo(tokens, i+1, "then")

      if tokens[i-1] ~= "then" then
        writeError("missing 'then' near '%s'", tokens[i - 1])
        return
      end

      local result, _err = evaluateCommandChain(command)

      if _err then writeError(_err) end

      if result ~= 0 then
        i = seekBalanced(tokens, i, "else", "elseif", "end")

        if not i then
          return writeError("could not find matching else/elseif/end")
        end

        if tokens[i-1] == "elseif" then i = i - 1 end

        if tokens[i-1] == "else" then
          local elseblock
          i, elseblock = seekBalanced(tokens, i, "end")

          local _result, __err = evaluateTokens(elseblock)
          if not _result then return nil, __err end
        end

      else
        local ifblock
        i, ifblock = seekBalanced(tokens, i, "else", "elseif", "end")
        if tokens[i-1] ~= "end" then i = seekBalanced(tokens, i, "end") end

        local _result, __err = evaluateTokens(ifblock)
        if not _result then return nil, __err end
      end

    elseif token == "else" then
      local _i = seekBalanced(tokens, i, "end")

      if not _i then
        return writeError(unexpected("else", tokens[i-1]))

      else
        i = _i
      end

    elseif token == "for" then
      local command
      i, command = readTo(tokens, i+1, "do")

      local varname = table.remove(command, 1)
      if table.remove(command, 1) ~= "in" then
        return writeError("expected 'in' near '%s'", tokens[i-1])
      end

      local result, output = evaluateCommandChain(command,
        { output = true })

      if result then
        local forblock
        i, forblock = seekBalanced(tokens, i, "end")
        local old = os.getenv(varname)

        for line in output:gmatch("[^\n]+") do
          stdlib.setenv(varname, line)
          local _result, _err = evaluateTokens(forblock)
          if not _result then break end
        end

        stdlib.setenv(varname, old)
      else
        return writeError(output)
      end

    elseif token == "while" then
      local command
      i, command = readTo(tokens, i, "do")

    elseif token == "end" then
      return writeError(unexpected("end", tokens[i-1]))

    elseif token == "SPLIT;SPLIT" or token == "SPLIT\nSPLIT" or
        i == #tokens then
      if #currentCommand == 0 and token == "SPLIT;SPLIT" then
        return writeError(unexpected(";", tokens[i-1]))
      end

      if i == #tokens and token ~= "SPLIT;SPLIT" and
          token ~= "SPLIT\nSPLIT" then
        currentCommand[#currentCommand+1] = token
      end

      if #currentCommand > 0 then
        local result, err = evaluateCommandChain(currentCommand)
        currentCommand = {}

        if result ~= 0 then
          if shopts.errexit then
            os.exit(1)
          else
            if err then writeError("%s", err) end
            return
          end
        end
      end

    else
      currentCommand[#currentCommand+1] = token
    end

    i = i + 1
  end

  return true
end

-- Takes a chunk and evaluates it.
local function evaluateChunk(chunk)
  chunk = chunk
    -- strip spaces at the beginning
    :gsub("^ *", "")
    -- strip comments
    :gsub("#[^\n]*", "")
  if #chunk == 0 then return end
  local tokens, err = tokenize(chunk)
  if not tokens then
    writeError(err)
    return
  end
  return evaluateTokens(tokens)
end

function builtins.source(argt)
  if #argt == 0 then
    writeError("usage: source filename")
    return 1
  end
  local handle, err = io.open(argt[1], "r")
  if not handle then
    writeError(err)
    return 1
  end
  local data = handle:read("a")
  handle:close()
  return evaluateChunk(data) and 0 or 1
end
builtins["."] = builtins.source
builtins[":"] = function() end

local history = {}
if os.getenv("HOME") then
  local hist = io.open(os.getenv("HOME").."/.vbls_history", "r")
  if hist then
    for line in hist:lines() do
      history[#history + 1] = line
    end
    hist:close()
  end
end

if opts.c then
  return evaluateChunk(opts.c)
end

local profile = stdlib.realpath("/etc/profile")
if profile then builtins.source{"/etc/profile"} end

local to_source
if opts.login then
  to_source = stdlib.realpath(os.getenv("HOME").."/.profile")
else
  to_source = stdlib.realpath(os.getenv("HOME").."/.vblsrc")
end

if to_source then
  builtins.source{to_source}
end

local _rl_opts = { history = history, exit = function()
  -- save history on shell exit
  local handle, err = io.open(os.getenv("HOME").."/.vbls_history", "w")
  if not handle then
    writeError("could not save history: %s", err)
  else
    handle:write(table.concat(history, "\n"))
    handle:close()
  end
  os.exit()
end }

while true do
  io.write("% ")
  evaluateChunk(readline(_rl_opts))
end
