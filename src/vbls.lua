#!/usr/bin/env lua
-----------------------------------
-- The Vaguely Bourne-Like Shell --
--   by the ULOS 2 Developers    --
-----------------------------------
--
-- This shell should work both on Linux and on ULOS 2.

local argv = table.pack(...)

local fork

-- this is how we detect running under ULOS 2.
-- Mostly used to select which fork() to use.
if type(argv) == "table" then
  argv = argv[1]
  fork = require("syscalls").fork
else
  local _fork = require("posix.unistd").fork
  fork = function(func)
    local pid, _, errno = _fork()
    if not pid then
      return nil, errno
    end

    if pid == 0 then
      func()
    else
      return pid
    end
  end
end

local stat = require("posix.sys.stat")
local errno = require("posix.errno")
local stdlib = require("posix.stdlib")
local unistd = require("posix.unistd")
local readline = require("readline")

local defaultPath = "/bin:/sbin:/usr/bin"

local commandPaths = {}

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
    return nil, "command not found"
  end
end

local function findCommand(name)
  local path = os.getenv("PATH") or defaultPath
  if commandPaths[cpath] then return commandPaths[cpath] end

  for search in path:gmatch("[^:]+") do
    local statx, cpath = subFindCommand(search, name)
    if statx then
      commandPaths[name] = cpath
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
        if c == ";" then
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
    return nil, "unfinished string"
  end

  return tokens
end

local function evaluateChunk()
end

local history = {}
local hist = io.open(os.getenv("HOME").."/.vbls_history", "r")
if hist then
  for line in hist:lines() do
    history[#history + 1] = line
  end
  hist:close()
end

local opts = { history = history }
while true do
  evaluateChunk(readline(opts))
end
