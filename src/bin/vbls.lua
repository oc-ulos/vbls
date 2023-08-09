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
local glob = require("posix.glob")
local unistd = require("posix.unistd")
local signal = require("posix.signal")

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
local libgen = require("posix.libgen")
local stdlib = require("posix.stdlib")
local readline = require("readline")

local args, opts = require("getopt").getopt({
  options = {
    h = false, help = false,
    v = false, version = false,
    c = true, login = false,
    e = false, x = false,
  },
  allow_finish = true,
  exit_on_bad_opt = true,
  help_message = argv[0] .. ": pass '--help' for usage information\n"
}, argv)

if opts.h or opts.help then
  io.stderr:write([=[
usage: vbls [options] [script [arguments ...]]
The Vaguely Bourne-Like Shell.  Theoretically saner than Bash.  See vbls(1) for
detailed information on syntax and whatnot.

  -c STRING     Execute STRING and exit.
  -e            Set shell option 'errexit'
  -x            Set shell option 'showcommands'
  --login       Specify that this VBLS is a login shell
  -h,--help     Show this message
  -v,--version  Print the shell version

Copyright (c) 2022 ULOS Developers under the GNU GPLv3.
]=])
  os.exit(0)
end

if opts.v or opts.version then
  print("VBLS ".._VBLS_VERSION)
end

local defaultPath = "/bin:/sbin:/usr/bin"

local commandPaths = {}
local shopts = {
  cachepaths = true,
  errexit = not not opts.e,
  showcommands = not not opts.x
}

local home_dir, interactive

local function writeError(err, ...)
  io.stdout:flush()
  if type(err) == "number" then err = errno.errno(err) end
  io.stderr:write("vbls: ", string.format(err, ...), "\n")
  io.stderr:flush()
end

-- some default environment setup
stdlib.setenv("0", argv[0])
for i=1, #args, 1 do
  stdlib.setenv(tostring(i), tostring(args[i]))
end
stdlib.setenv("VBLS_VERSION", _VBLS_VERSION)

if opts.login then
  local home = require("posix.pwd").getpwuid(unistd.geteuid())
  home = home and home.pw_dir or "/"
  stdlib.setenv("HOME", home)

  if not stat.stat(home) then
    writeError("warning: home directory does not exist")

  else
    unistd.chdir(home)
  end

else
  stdlib.setenv("HOME", os.getenv("HOME") or "/")
end

home_dir = stdlib.getenv("HOME")

stdlib.setenv("SHLVL",
  tostring(math.floor(tonumber(os.getenv("SHLVL") or 0) + 1)))
stdlib.setenv("PWD", unistd.getcwd())

local function unexpected(token, near)
  return string.format("unexpected '%s' near '%s'", token, near or "<EOF>")
end


-- builtins
local builtins = {}
local aliases = {}

function builtins.alias(argt)
  if #argt == 0 then
    for k,v in pairs(aliases) do print(k.."='"..v.."'") end

  elseif #argt == 1 then
    if aliases[argt[1]] then
      print(aliases[argt[1]])
    end

  elseif #argt == 2 then
    aliases[argt[1]] = argt[2]

  else
    writeError("usage: alias [name [program]]")
    return 1
  end

  return 0
end

function builtins.unalias(argt)
  if #argt == 0 then
    writeError("usage: unalias name")
    return 1
  end

  aliases[argt[1]] = nil
  return 0
end

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

-- like echo, but delimits exclusively with a newline
function builtins.echo_nl(argt, _, output)
  output = output or 1
  local outstr = ""

  for i=1, #argt, 1 do
    outstr = outstr .. tostring(argt[i]) .. "\n"
  end

  unistd.write(output, outstr)
  return 0
end

function builtins.set(argt)
  if #argt == 0 then
    for k, v in pairs(stdlib.getenv()) do
      print(tostring(k).."="..v:gsub("%c", function(cc)
        if cc == "\27" then cc = "\5" end
        return "\\" .. string.char(cc:byte() + 96)
      end))
    end

  else
    local _args, _opts = require("getopt").getopt({ options={},
      allow_finish=true }, argt)

    if #_args == 1 or _opts.help then
      writeError("set: usage: set [options] [VAR VAL]")
      if opts.help then
        io.stderr:write([[
  -n                negate others
  -e,--errexit      exit on error
  -x,--showcommand  show executed commands
     --cachepaths   cache command paths]])
      end
      return 1
    end

    if _opts.e or _opts.errexit then shopts.errexit = not opts.n end
    if _opts.x or _opts.showcommand then shopts.showcommand = not _opts.n end
    if _opts.cachepaths then shopts.cachepaths = not _opts.n end

    if #_args > 1 then
      stdlib.setenv(_args[1], table.concat(_args, " ", 2))
    end
  end

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

  local realto, eno = stdlib.realpath(to)

  if not realto then
    writeError("cd: %s: %s", to, eno)
    return 1
  end

  local oldwd = unistd.getcwd()
  local ok, err = unistd.chdir(realto)

  if not ok then
    writeError("cd: %s: %s", to, err)
    return 1
  end

  stdlib.setenv("OLDPWD", oldwd)
  stdlib.setenv("PWD", to)

  return 0
end

function builtins.equals(argt)
  return argt[1] == argt[2] and 0 or 1
end

function builtins.umask(argt, _, output)
  output = output or 1
  local perms = require("permissions")

  local quiet = true
  if argt[1] == "-s" then quiet = false table.remove(argt, 1) end

  if not argt[1] then
    writeError("umask: permission mask required")
    return 1
  end

  local mask
  if tonumber(argt[1]) then
    mask = tonumber(argt[1])
  else
    mask = perms.strtobmp(argt[1])
  end

  if not mask then
    writeError("umask: invalid permission mask")
  end

  if not quiet then unistd.write(output, tostring(mask).."\n") end
  stat.umask(mask)

  return 0
end

function builtins.builtins(_, _, output)
  local b = {}
  for k in pairs(builtins) do b[#b+1] = k end
  unistd.write(output, table.concat(b, "\n"))
  return 0
end

function builtins.exit(argt)
  if #argt == 0 then
    os.exit(0)
  else
    os.exit(tonumber(argt[1]))
  end
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

local whitespace = { [" "] = true, ["\n"] = false, ["\t"] = true }
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
  local in_string, in_comment, in_subst, subst_level = false, false, false, 0
  local prev_char

  for c in chunk:gmatch(".") do
    if in_comment then
      in_comment = c ~= "\n"

      if #tokens[#tokens] > 0 then
        tokens[#tokens+1] = ""
      end

    elseif in_string then
      if prev_char == "\\" then
        if escapes[c] then
          tokens[#tokens] = tokens[#tokens] .. escapes[c]
          c = "ESCAPED"

        else
          tokens[#tokens] = tokens[#tokens] .. "\\" .. c
        end

      elseif c == "'" then
        in_string = false

      elseif c ~= "\\" then
        tokens[#tokens] = tokens[#tokens] .. c
      end

    elseif c == "#" then
      in_comment = true

    elseif in_subst then
      tokens[#tokens] = tokens[#tokens] .. c

      if c == ")" then
        subst_level = subst_level - 1

        if subst_level <= 0 then
          in_subst = false
        end

      elseif c == "(" and prev_char == "$" then
        subst_level = subst_level + 1
      end


    else

      if whitespace[c] then
        if #tokens[#tokens] > 0 then
          tokens[#tokens+1] = ""
        end

      elseif prev_char == "$" and c == "(" then
        if #tokens[#tokens] > 1 then
          return nil, unexpected("$(", tokens[#tokens])
        end

        tokens[#tokens] = tokens[#tokens] .. c
        in_subst = true
        subst_level = 1

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

      elseif c ~= "\\" then
        tokens[#tokens] = tokens[#tokens] .. c
      end
    end

    prev_char = c
  end

  if in_string then
    return nil, "unfinished string near '"..tokens[#tokens].."'"
  end

  if in_subst then
    return nil, "unfinished substitution near '"..tokens[#tokens].."'"
  end

  if #tokens[#tokens] == 0 and prev_char ~= "'" then
    tokens[#tokens] = nil
  end

  return tokens
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

local evaluateChunk

-- Takes a single command and evaluates it.  If `input` or `output` is set,
-- the command's standard input or output will automatically redirect to
-- the file descriptors to which they point.
local function evaluateCommand(command)
  local i = 1
  while command[i] do
    if not command[i] then break end

    if command[i]:sub(1,2) == "$(" and command[i]:sub(-1) == ")" then
      local result, output = evaluateChunk(command[i]:sub(3,-2), true)

      local insert = {}

      if result and output then
        for line in output:gmatch("[^\n]+") do
          insert[#insert+1] = line
        end
      end

      table.remove(command, i)

      for n=#insert, 1, -1 do
        table.insert(command, i, insert[n])
      end

      i = i + #insert

    elseif command[i] == ";" then
      table.remove(command, i)

    elseif command[i]:find("[%*%?]") or command[i]:find("%[[^%[%]]%]") then
      local results = glob.glob(command[i], 0)
      if results then
        table.remove(command, i)

        for n=#results, 1, -1 do
          table.insert(command, i, results[n])
        end

      else
        i = i + 1
      end

    else
      command[i] = command[i]:gsub("%$(%b{})", function(v)
        return os.getenv((v:sub(2,-2))) or ""
      end):gsub("%$([%w_]+)", function(v)
        return os.getenv(v) or ""
      end)

      i = i + 1
    end
  end

  if shopts.showcommand then
    local c = ""
    for n=1, #command do c = c .. tostring(command[n]) .. " " end
    io.stderr:write("+ '", c, "'\n")
  end

  local path, err = findCommand(command[1])
  if not path then return nil, err end

  local argt = {table.unpack(command, 2)}
  argt[0] = command[1]

  if builtins[argt[0]] then
    return builtins[argt[0]](argt, command.input, command.output)

  else
    local old = unistd.getpgrp()
    local pid = fork(function()
      if command.input then
        assert(unistd.dup2(command.input, 0))
        --unistd.close(command.input)
      end

      if command.output then
        assert(unistd.dup2(command.output, 1))
        --unistd.close(command.output)
      end

      if interactive then
        unistd.tcsetpgrp(2, unistd.getpid())
        unistd.setpid("p", unistd.getpid(), unistd.getpid())
      end

      local _, _err, _errno = unistd.exec(path, argt)

      if interactive then
        unistd.tcsetpgrp(2, old)
        unistd.setpid("p", unistd.getpid(), old)
      end
      io.stderr:write(("vbls: %s: %s\n"):format(path, _err))
      os.exit(_errno)
    end)

    if command.input then unistd.close(command.input) end

    local _, _, status = wait(pid)

    if interactive then
      unistd.setpid("p", unistd.getpid(), pid)
      unistd.tcsetpgrp(2, old)
      unistd.setpid("p", unistd.getpid(), old)
    end

    return status
  end
end

-- Take a command chain, e.g 'a && b || c', and process it.
local function evaluateCommandChain(tokens, flags)
  local commands = {{}}

  if type(flags) == "boolean" then
    flags = { output = flags }
  end

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
      if operator == "||" then
        if last_result == 0 or result == 0 then
          last_result = 0

        else
          last_result = result
        end

      else
        last_result = result
        if operator == "&&" and result ~= 0 then
          break
        end
      end
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

local function append(currentCommand, token)
  if #currentCommand == 0 and aliases[token] then
    local bits = tokenize(aliases[token])
    for k=1, #bits, 1 do
      currentCommand[#currentCommand+1] = bits[k]
    end

  else
    currentCommand[#currentCommand+1] = token
  end
end

-- Takes a set of tokens and evaluates them.  This is where things like
-- flow control happen.
local function evaluateTokens(tokens, captureOutput)
  local i = 1
  local currentCommand = {}

  local commandoutput = ""

  while tokens[i] do
    local token = tokens[i]

    if token == "if" or token == "elseif" then
      local command
      i, command = readTo(tokens, i+1, "then")

      if tokens[i-1] ~= "then" then
        writeError("missing 'then' near '%s'", tokens[i - 1])
        return
      end

      local result, _err = evaluateCommandChain(command, captureOutput)

      if not result and _err then writeError(_err) end
      if captureOutput then commandoutput = commandoutput .. _err end

      if result ~= 0 then
        i = seekBalanced(tokens, i, "else", "elseif", "end")

        if not i then
          return writeError("could not find matching else/elseif/end")
        end

        if tokens[i-1] == "elseif" or tokens[i-1] == "end" then
          i = i - 1

        elseif tokens[i-1] == "else" then
          local elseblock
          i, elseblock = seekBalanced(tokens, i, "end")
          i = i - 1

          local _result, __err = evaluateTokens(elseblock, captureOutput)
          if not _result then return nil, __err end
          if captureOutput then commandoutput = commandoutput .. __err end
        end

      else
        local ifblock
        i, ifblock = seekBalanced(tokens, i, "else", "elseif", "end")

        if not i then
          return writeError("could not find matching else/elseif/end")
        end

        if tokens[i-1] ~= "end" then
          i = seekBalanced(tokens, i, "end")
          i = i - 1

        else
          i = i - 1
        end

        local _result, __err = evaluateTokens(ifblock, captureOutput)
        if not _result then return nil, __err end
        if captureOutput then commandoutput = commandoutput .. __err end
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

      table.insert(command, 1, "echo_nl")
      local result, output = evaluateCommandChain(command,
        { output = true })

      if result then
        local forblock
        i, forblock = seekBalanced(tokens, i, "end")
        local old = os.getenv(varname)

        for line in output:gmatch("[^\n]+") do
          stdlib.setenv(varname, line)
          local _result, _output = evaluateTokens(forblock, captureOutput)
          if not _result then break end
          commandoutput = commandoutput .. (_output or "")
        end

        stdlib.setenv(varname, old)
      else
        return writeError(output)
      end

    elseif token == "while" then
      return writeError("'while' is not yet supported")
      --local command
      --i, command = readTo(tokens, i, "do")

      -- TODO: do something here

    elseif token == "end" then
      return writeError(unexpected("end", tokens[i-1]))

    elseif token == ";" or token == "\n" or
        i == #tokens then
      if #currentCommand == 0 and token == ";" then
        return writeError(unexpected(";", tokens[i-1]))
      end

      if i == #tokens and token ~= ";" and
          token ~= "\n" then
        append(currentCommand, token)
      end

      if #currentCommand > 0 then
        local result, err = evaluateCommandChain(currentCommand, captureOutput)
        currentCommand = {}

        if result ~= 0 then
          if shopts.errexit then
            os.exit(1)

          else
            if err then writeError("%s", err) end
            return
          end
        end

        if captureOutput then commandoutput = commandoutput .. err end
      end

    else
      append(currentCommand, token)
    end

    i = i + 1
  end

  return true, captureOutput and commandoutput
end

-- Takes a chunk and evaluates it.
evaluateChunk = function(chunk, captureOutput)
  chunk = chunk
    -- strip spaces at the beginning
    :gsub("^ *", "")

  if #chunk == 0 then return end
  local tokens, err = tokenize(chunk)

  if not tokens then
    writeError(err)
    return
  end

  return evaluateTokens(tokens, captureOutput)
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

interactive = true

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

local utsname = require("posix.sys.utsname")

local function proc_cwd(dir)
  if dir:sub(1,#home_dir) == home_dir then
    dir = "~"..dir:sub(#home_dir+1)
  end

  return dir
end

local function prompt(p)
  return (p
    :gsub("\\W", libgen.basename(proc_cwd(unistd.getcwd())))
    :gsub("\\w", proc_cwd(unistd.getcwd()))
    :gsub("\\h", utsname.uname().nodename)
    :gsub("\\v", _VBLS_VERSION)
    :gsub("\\s", "vbls")
    :gsub("\\u", os.getenv("USER"))
  )
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

signal.signal(signal.SIGTTIN, signal.SIG_IGN)
signal.signal(signal.SIGTTOU, signal.SIG_IGN)
signal.signal(signal.SIGTSTP, signal.SIG_IGN)

while true do
  io.write(prompt(os.getenv("PS1") or "% "))
  evaluateChunk(readline(_rl_opts))
end
