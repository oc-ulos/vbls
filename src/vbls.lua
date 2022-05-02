#!/usr/bin/env lua
-----------------------------------
-- The Vaguely Bourne-Like Shell --
--   by the ULOS 2 Developers    --
-----------------------------------
--
-- This shell should work both on Linux and on ULOS 2.

local argv = require("argv").command("vbls", ...)

local fork
local stat = require("posix.sys.stat")
local errno = require("posix.errno")
local stdlib = require("posix.stdlib")
local unistd = require("posix.unistd")
local readline = require("readline")

local args, opts = require("getopt").getopt({
  opts = {
    h = false, help = false,
    c = true, login = false,
    e = false, x = false,
  },
  allow_finish = true,
  exit_on_bad_opt = true,
  help_message = argv[0] .. ": pass '--help' for usage information\n"
})

-- this is how we detect running under ULOS 2.
-- Mostly used to select which fork() to use.
if type(argv) == "table" then
  argv = argv[1]
  fork = require("syscalls").fork
else
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

local defaultPath = "/bin:/sbin:/usr/bin"

local commandPaths = {}
local shopts = {
  cachepaths = true,
  errexit = false,
  showcommands = false
}

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

      else
        if c == ";" or c == "\n" then
          if #tokens[#tokens] > 0 then
            tokens[#tokens+1] = c

          else
            tokens[#tokens] = c
          end

          tokens[#tokens+1] = ""
        end

      end
    end

    prev_char = c
  end

  if in_string then
    return nil, "unfinished string near '"..tokens[#tokens].."'"
  end

  return tokens
end

local function writeError(err)
  io.stdout:flush()
  if type(err) == "number" then err = errno.errno(err) end
  io.stderr:write("vbls: ", err, "\n")
  io.stderr:flush()
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

local function evaluateTokens(tokens)
  local i = 1

  while true do
    local token = tokens[i]

    if token == "if" or token == "elseif" then
      local command
      i, command = readTo(tokens, i, "then")

      if tokens[i] ~= "then" then
        writeError("missing 'then' near " .. tokens[i - 1])
        return
      end

      local result, _err = evaluateCommandChain(command)
      if _err then writeError(_err) end

      if result ~= 0 then
        i = seekBalanced(tokens, i, "else", "elseif", "end")
      end

    elseif token == "else" then
      if tokens[i-1] then
        writeError("unexpected 'else' near '"..tokens[i-1].."'")
      else
        writeError("unexpected 'else'")
      end
      return

    elseif token == "for" then
      local command
      i, command = readTo(tokens, i, "do")

      local varname = table.remove(command, 1)
      if table.remove(command, 1) ~= "in" then
        return writeError("expected 'in' near '" .. tokens[i-1] .. "'")
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
        return
      end

    elseif token == "while" then
      local command
      i, command = readTo(tokens, i, "do")

    elseif token == "end" then
      if tokens[i-1] then
        writeError("unexpected 'end' near '"..tokens[i-1].."'")
      else
        writeError("unexpected 'end'")
      end
      return
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

local _rl_opts = { history = history }
while true do
  evaluateChunk(readline(_rl_opts))
end
