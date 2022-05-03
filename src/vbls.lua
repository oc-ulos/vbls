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

local stat = require("posix.sys.stat")
local wait = require("posix.sys.wait").wait
local errno = require("posix.errno")
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
stdlib.setenv("HOME", "/", true)

local function subFindCommand(path, name)
  local test1 = stdlib.realpath(path .. "/" .. name)
  local test2 = test1 .. ".lua"

  local statx, cpath = stat.lstat(test1), test1
  if not statx then
    statx, cpath = stat.lstat(test2), test2
  end

  if statx then
    return statx, cpath
  else
    return nil, name .. ": command not found"
  end
end

local function findCommand(name)
  local path = os.getenv("PATH") or defaultPath
  if shopts.cachepaths and commandPaths[name] then
    return commandPaths[name] end

  if name:find("/", nil, true) then
    return name
  end

  for search in path:gmatch("[^:]+") do
    local statx, cpath = subFindCommand(search, name)
    if statx then
      if shopts.cachepath then commandPaths[name] = cpath end
      return cpath
    end
  end

  return nil, "command not found"
end

local whitespace = { [" "] = true, ["\n"] = true, ["\t"] = true }

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
      if c == "'" then
        in_string = false
      else
        tokens[#tokens] = tokens[#tokens] .. c
      end

    else

      if whitespace[c] and #tokens[#tokens] > 0 then
        tokens[#tokens+1] = ""

      elseif c == "'" then
        in_string = true
        if prev_char == c then
          tokens[#tokens] = tokens[#tokens] .. c
        end

      elseif c == ";" or c == "\n" then
        if #tokens[#tokens] > 0 then
          tokens[#tokens+1] = c

        else
          tokens[#tokens] = c
        end

        tokens[#tokens+1] = ""

      else
        tokens[#tokens] = tokens[#tokens] .. c
      end
    end

    prev_char = c
  end

  if in_string then
    return nil, "unfinished string near '"..tokens[#tokens].."'"
  end

  return tokens
end

local function writeError(err, ...)
  io.stdout:flush()
  if type(err) == "number" then err = errno.errno(err) end
  io.stderr:write("vbls: ", string.format(err, ...), "\n")
  io.stderr:flush()
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

-- TODO: builtin commands
local function evaluateCommand(command)
  local path, err = findCommand(command[1])
  if not path then return nil, err end

  local argt = {table.unpack(command, 2)}
  argt[0] = command[1]

  local pid = fork(function()
    if command.input then
      unistd.dup2(command.input, 0)
      unistd.close(command.input)
    end
    if command.output then
      unistd.dup2(command.output, 1)
      unistd.close(command.output)
    end
    local _, _err, _errno = unistd.exec(path, argt)
    io.stderr:write(("vbls: %s: %s\n"):format(path, _err))
    os.exit(_errno)
  end)

  local _, _, status = wait(pid)
  return status
end

local function evaluateCommandChain(tokens)
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

  local i = 1
  while commands[i] do
    local cmd = commands[i]
    local prog_out, prog_in = unistd.pipe()
    i = i + 1

    local operator = commands[i]
    if operator == "|" then
      cmd.output = prog_out
      commands[#commands+1].input = prog_in
    end

    local result, err = evaluateCommand(cmd)
    unistd.close(prog_out)
    unistd.close(prog_in)
    i = i + 1
  end
end

local function evaluateTokens(tokens)
  local i = 1
  local currentCommand = {}

  while tokens[i] do
    local token = tokens[i]

    if token == "if" or token == "elseif" then
      local command
      i, command = readTo(tokens, i, "then")

      if tokens[i] ~= "then" then
        writeError("missing 'then' near '%s'", tokens[i - 1])
        return
      end

      local result, _err = evaluateCommandChain(command)
      if _err then writeError(_err) end

      if result ~= 0 then
        i = seekBalanced(tokens, i, "else", "elseif", "end")
        if tokens[i-1] == "elseif" then i = i - 1 end
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
      i, command = readTo(tokens, i, "do")

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
          local _result = evaluateTokens(forblock)
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

    elseif token == ";" or token == "\n" or i == #tokens then
      if #currentCommand == 0 and token == ";" then
        return writeError(unexpected(";", tokens[i-1]))
      end

      if i == #tokens and token ~= ";" and token ~= "\n" then
        currentCommand[#currentCommand+1] = token
      end

      if #currentCommand > 0 then
        local result, err = evaluateCommandChain(currentCommand)
        currentCommand = {}

        if result ~= 0 and shopts.errexit then
          os.exit(1)
          return
        end
      end

    else
      currentCommand[#currentCommand+1] = token
    end

    i = i + 1
  end
end

local function evaluateChunk(chunk)
  local tokens, err = tokenize(chunk)
  if not tokens then
    writeError(err)
    return
  end
  return evaluateTokens(tokens)
end

local history = {}
local hist = io.open(os.getenv("HOME").."/.vbls_history", "r")
if hist then
  for line in hist:lines() do
    history[#history + 1] = line
  end
  hist:close()
end

if opts.c then
  return evaluateChunk(opts.c)
end

local _rl_opts = { history = history }
while true do
  io.write("% ")
  evaluateChunk(readline(_rl_opts))
end
