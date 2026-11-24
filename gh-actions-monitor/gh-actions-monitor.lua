#!/usr/bin/env luajit
local VERSION = "0.2.1"
local WINDOWS = package.config:sub(1, 1) == "\\"

local function q(s)
  if WINDOWS then
    return '"' .. tostring(s):gsub('([%%"])', "\\%1") .. '"'
  end
  return "'" .. tostring(s):gsub("'", [['"'"']]) .. "'"
end

local function cmd(s)
  -- LuaJIT's io.close on pipes always returns true and never the child's
  -- exit status, so the rc is echoed by the shell itself and parsed back.
  if WINDOWS then
    local output_path = os.tmpname()
    local rc_path = output_path .. ".rc"
    os.execute(s .. " > " .. q(output_path) .. " 2>&1 & (if errorlevel 1 (echo 1) else (echo 0)) > " .. q(rc_path))
    local output = io.open(output_path, "r")
    local out = output and output:read("*a") or ""
    if output then output:close() end
    local status = io.open(rc_path, "r")
    local rc = status and tonumber(status:read("*a")) or 1
    if status then status:close() end
    os.remove(output_path)
    os.remove(rc_path)
    return out, rc
  end
  local f = assert(io.popen(s .. " 2>&1 </dev/null; printf '\\nRC=%d\\n' \"$?\""))
  local out = f:read("*a") or ""
  f:close()
  local rc = 1
  local rc_line = out:match("RC=(%d+)%s*$")
  if rc_line then
    rc = tonumber(rc_line) or 1
    out = out:gsub("RC=%d+%s*$", "")
  end
  return out, rc
end

local function sleep(seconds)
  if WINDOWS then
    os.execute("powershell.exe -NoProfile -NonInteractive -Command " .. q(
      ("Start-Sleep -Seconds %s"):format(tostring(seconds))))
  else
    os.execute("sleep " .. tostring(seconds))
  end
end

local function tsv(line, n)
  local r, p = {}, 1
  for i = 1, n - 1 do
    local j = line:find("\t", p, true)
    r[i], p = j and line:sub(p, j - 1) or line:sub(p), j and j + 1 or #line + 1
  end
  r[n] = line:sub(p)
  for i = 1, n do r[i] = r[i] or "" end
  return r
end

local function usage()
  io.stderr:write([[
gh-actions-monitor - poll GitHub Actions runs and PR checks via gh

Usage:
  gh-actions-monitor run <run-id> [--repo OWNER/REPO] [--interval SEC] [--timeout SEC] [--soft-deadline SEC] [--verbose]
  gh-actions-monitor pr-checks <pr> [--repo OWNER/REPO] [--interval SEC] [--timeout SEC] [--soft-deadline SEC] [--fail-fast] [--verbose]
Subcommands:
  run        poll one GitHub Actions workflow run until it completes
  pr-checks  poll all checks of a pull request until they settle
]])
end

io.stdout:setvbuf("line")

local args = {...}
if #args == 0 or args[1] == "-h" or args[1] == "--help" then usage(); os.exit(0) end
if args[1] == "--version" then print(VERSION); os.exit(0) end

local mode, target = table.remove(args, 1), table.remove(args, 1)
if not target or (mode ~= "run" and mode ~= "pr-checks") then usage(); os.exit(5) end

local opt = { interval = 30, timeout = 1800 }
local i = 1
while i <= #args do
  local a = args[i]
  if a == "-R" or a == "--repo" then i = i + 1; opt.repo = args[i]
  elseif a == "-i" or a == "--interval" then i = i + 1; opt.interval = tonumber(args[i])
  elseif a == "--timeout" then i = i + 1; opt.timeout = tonumber(args[i])
  elseif a == "--soft-deadline" then i = i + 1; opt.soft = tonumber(args[i])
  elseif a == "--fail-fast" then opt.fail_fast = true
  elseif a == "-v" or a == "--verbose" then opt.verbose = true
  else io.stderr:write("Unknown arg: " .. tostring(a) .. "\n"); usage(); os.exit(5) end
  i = i + 1
end

local repo = opt.repo and (" --repo " .. q(opt.repo)) or ""
local start, polls = os.time(), 0

local function stop(kind, fields, code)
  io.stdout:write("result=" .. kind)
  for k, v in pairs(fields or {}) do io.stdout:write((" %s=%s"):format(k, tostring(v))) end
  io.stdout:write((" elapsed=%ds polls=%d\n"):format(os.time() - start, polls))
  os.exit(code)
end

local function check_deadline(fields)
  local elapsed = os.time() - start
  if opt.soft and elapsed >= opt.soft then stop("soft_deadline_exceeded", fields, 3) end
  if elapsed >= opt.timeout then stop("timeout", fields, 4) end
end

local function monitor_run()
  local jq = q([[ [.databaseId,.status,(.conclusion // ""),.workflowName,.url,.updatedAt] | @tsv ]])
  local json = "databaseId,status,conclusion,workflowName,url,updatedAt"

  while true do
    polls = polls + 1
    local out, rc = cmd("gh run view " .. q(target) .. repo .. " --json " .. json .. " --jq " .. jq)
    local elapsed = os.time() - start
    if rc ~= 0 then io.stderr:write(out); os.exit(5) end

    local f = tsv(out:gsub("%s+$", ""), 6)
    local id, status, conclusion, workflow, url, updated = f[1], f[2], f[3], f[4], f[5], f[6]

    io.stdout:write(("poll=%d elapsed=%ds run=%s workflow=%s status=%s conclusion=%s updated=%s\n")
      :format(polls, elapsed, id, workflow, status, conclusion ~= "" and conclusion or "-", updated))

    if status == "completed" then
      if conclusion == "success" then stop("success", { url = url }, 0) end
      stop("run_failed", { conclusion = conclusion ~= "" and conclusion or "unknown", url = url }, 2)
    end

    check_deadline({ status = status, url = url })
    sleep(opt.interval)
  end
end

local function monitor_pr_checks()
  local json = "name,bucket,state,workflow,link,startedAt,completedAt"
  local jq = q([[ .[] | [.name,.bucket,.state,.workflow,.link] | @tsv ]])

  while true do
    polls = polls + 1
    local out, rc = cmd("gh pr checks " .. q(target) .. repo .. " --json " .. json .. " --jq " .. jq)
    local elapsed = os.time() - start
    if rc ~= 0 then io.stderr:write(out); os.exit(5) end

    local pending, failed, total, link = 0, 0, 0, ""

    for line in out:gmatch("[^\n]+") do
      total = total + 1
      local f = tsv(line, 5)
      local name, bucket, state, workflow, this_link = f[1], f[2], f[3], f[4], f[5]
      if this_link ~= "" then link = this_link end

      io.stdout:write(("poll=%d elapsed=%ds check=%s bucket=%s state=%s workflow=%s\n")
        :format(polls, elapsed, name, bucket, state, workflow))

      if bucket == "pending" then pending = pending + 1 end
      if bucket == "fail" or state:match("FAILURE|ERROR|TIMED_OUT|CANCELLED") then failed = failed + 1 end
    end

    if total == 0 then
      io.stdout:write(("poll=%d elapsed=%ds note=no_checks_yet\n"):format(polls, elapsed))
    elseif failed > 0 and opt.fail_fast then
      stop("checks_failed", { pending = pending, failed = failed, total = total, link = link }, 2)
    elseif pending == 0 then
      if failed == 0 then stop("success", { pending = 0, failed = 0, total = total, link = link }, 0) end
      stop("checks_failed", { pending = 0, failed = failed, total = total, link = link }, 2)
    end

    check_deadline({ pending = pending, failed = failed, total = total, link = link })
    sleep(opt.interval)
  end
end

if mode == "run" then monitor_run() else monitor_pr_checks() end
