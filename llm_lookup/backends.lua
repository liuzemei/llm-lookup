-- 模型来源：本机 Claude Code / Codex / 任意命令行，或 OpenAI / Anthropic 格式的 HTTP 接口
--
-- 每个 runner(b, system, prompt, out) 通过 out.delta(text) / out.reset() / out.done(err, finalText) 回报，
-- 返回 hs.task（用于取消）；出错时可以直接 out.done(err) 并返回 nil

local config = require("llm_lookup.config")
local U = require("llm_lookup.util")

local B = {}

B.NAMES = config.PROVIDER_NAMES

local tasks = {} -- 后台 hs.task 的引用，防止被 GC

---------------------------------------------------------------------------
-- 可执行文件
---------------------------------------------------------------------------

local binCache = {} -- name → 路径 / false（找不到）

local function parseWhich(out, name)
  for line in (out or ""):gmatch("[^\n]+") do
    if line:sub(1, 1) == "/" and line:sub(-#name - 1) == "/" .. name then return line end
  end
end

-- 在登录 shell 里找命令（nvm 之类的 PATH 只有登录 shell 里才有），异步，不卡界面
function B.prefetch()
  local names = { "claude", "codex" }
  for _, p in ipairs(config.values.profiles) do
    local cmd = p.provider == "command" and U.splitArgs(p.line or "")[1]
    if cmd and cmd:sub(1, 1) ~= "/" then names[#names + 1] = cmd end
  end
  for _, name in ipairs(names) do
    if not binCache[name] then
      local t
      t = hs.task.new(os.getenv("SHELL") or "/bin/zsh", function(_, out)
        tasks[t] = nil
        binCache[name] = parseWhich(out, name) or false
      end, { "-l", "-i", "-c", "command -v " .. U.shellQuote(name) })
      tasks[t] = true
      t:start()
    end
  end
end

function B.detected(name) return binCache[name] or nil end

local function findBinary(b, name)
  if b.path and b.path ~= "" then return b.path end
  if name:sub(1, 1) == "/" then return name end
  if binCache[name] == nil then -- 预取还没回来，就同步查一次
    binCache[name] = parseWhich(hs.execute("command -v " .. U.shellQuote(name), true), name) or false
  end
  return binCache[name] or nil
end

---------------------------------------------------------------------------
-- API Key（存在钥匙串里，每套配置一个，服务名 llm-lookup-<配置 id>）
---------------------------------------------------------------------------

local ACCOUNT = os.getenv("USER") or "llm-lookup"
local keyCache = {}

local function service(id) return "llm-lookup-" .. id end

function B.hasKey(p)
  local _, ok = hs.execute("/usr/bin/security find-generic-password -s " .. U.shellQuote(service(p)) .. " >/dev/null 2>&1")
  return ok == true
end

local function getKey(p)
  if keyCache[p] == nil then
    local out, ok = hs.execute("/usr/bin/security find-generic-password -w -s " .. U.shellQuote(service(p)) .. " 2>/dev/null")
    out = U.trim(out or "")
    keyCache[p] = ok and out ~= "" and out or false
  end
  return keyCache[p] or nil
end

-- key 通过 stdin 交给 security，不出现在进程参数里
function B.setKey(p, key, cb)
  key = U.trim(key or "")
  if key == "" or key:find('[%c"\\]') then return cb(false) end
  keyCache[p] = nil
  local t
  t = hs.task.new("/usr/bin/security", function()
    tasks[t] = nil
    cb(B.hasKey(p))
  end, { "-i" })
  tasks[t] = true
  t:setInput(('add-generic-password -U -a "%s" -s "%s" -w "%s"\n'):format(ACCOUNT, service(p), key))
  t:start()
end

function B.removeKey(p)
  keyCache[p] = nil
  hs.execute("/usr/bin/security delete-generic-password -s " .. U.shellQuote(service(p)) .. " >/dev/null 2>&1")
end

---------------------------------------------------------------------------
-- 进程 / HTTP
---------------------------------------------------------------------------

-- 启动进程，stdout 按行回调（raw = true 时按原始片段回调）
local function spawn(path, args, onOut, onExit, raw)
  -- 用了流式回调后 stdout 和 stderr 都从流式回调来，结束回调里基本是空的，两边都要攒
  local buf, errBuf = "", ""
  local task = hs.task.new(path, function(code, out, err)
    buf = buf .. (out or "")
    if buf ~= "" then onOut(buf) end
    onExit(code, errBuf .. (err or ""))
  end, function(_, out, err)
    errBuf = errBuf .. (err or "")
    out = out or ""
    if raw then
      if out ~= "" then onOut(out) end
      return true
    end
    buf = buf .. out
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then break end
      onOut((buf:sub(1, nl - 1):gsub("\r$", "")))
      buf = buf:sub(nl + 1)
    end
    return true
  end, args)
  if not task:start() then
    onExit(-1, "无法启动 " .. path)
    return nil
  end
  -- 必须关掉 stdin，否则 claude 等 CLI 会空等几秒看有没有管道输入
  task:closeInput()
  return task
end

local function exitError(code, err)
  local e = U.errTail(err)
  return e ~= "" and e or ("exit " .. tostring(code))
end

-- HTTP 走 curl：请求头（含 key）写进 0600 的临时配置文件，不出现在进程参数里
local function curlStream(url, headers, body, onData, onExit)
  local cfgPath, bodyPath = os.tmpname(), os.tmpname()
  local f = io.open(bodyPath, "w")
  f:write(hs.json.encode(body))
  f:close()
  local lines = { ('url = "%s"'):format(url), 'request = "POST"', ('data-binary = "@%s"'):format(bodyPath) }
  for _, h in ipairs(headers) do lines[#lines + 1] = 'header = "' .. h:gsub('[\\"]', "\\%0") .. '"' end
  f = io.open(cfgPath, "w")
  f:write(table.concat(lines, "\n"), "\n")
  f:close()

  -- SSE 的 data 行交给 onData；其它非空行（HTTP 出错时的响应体）攒起来当错误信息
  local raw = {}
  return spawn("/usr/bin/curl", { "-sS", "-N", "--fail-with-body", "-K", cfgPath }, function(line)
    local data = line:match("^data:%s?(.*)$")
    if data then
      if data ~= "[DONE]" then onData(U.decode(data) or {}) end
    elseif line:find("%S") and not line:match("^event:") and not line:match("^:") then
      raw[#raw + 1] = line
    end
  end, function(code, err)
    os.remove(cfgPath)
    os.remove(bodyPath)
    local msg
    if code ~= 0 then
      local text = table.concat(raw, "\n")
      local e = (U.decode(text) or {}).error
      msg = (type(e) == "table" and e.message) or (type(e) == "string" and e)
      if not msg then msg = U.errTail(text) ~= "" and U.errTail(text) or exitError(code, err) end
    end
    onExit(msg)
  end)
end

-- 补全接口地址：host 写到哪一级都行。只有域名时补上 /v1
local function apiUrl(host, endpoint)
  host = U.trim(host):gsub("/+$", "")
  if host:sub(-#endpoint) == endpoint then return host end
  if not host:match("^%a[%w+.-]*://[^/]+/") then host = host .. "/v1" end
  return host .. endpoint
end

local function orDefault(v, d) return (v and v ~= "") and v or d end

---------------------------------------------------------------------------
-- 各个来源
---------------------------------------------------------------------------

local runners = {}

function runners.claude(b, system, prompt, out)
  local bin = findBinary(b, "claude")
  if not bin then return out.done("找不到 claude 命令，请在设置里填写可执行文件路径") end
  local args = {
    -- prompt 总以中文开头（见 buildPrompt），不会被当成命令行选项
    "-p", prompt, "--system-prompt", system,
    "--output-format", "stream-json", "--include-partial-messages", "--verbose",
    -- 纯问答：不加载工具、MCP、设置、斜杠命令，也不落会话记录，启动最快
    "--tools", "", "--setting-sources", "", "--strict-mcp-config",
    "--disable-slash-commands", "--no-session-persistence",
  }
  if not U.isAuto(b.model) then table.insert(args, "--model"); table.insert(args, b.model) end
  if not U.isAuto(b.effort) then table.insert(args, "--effort"); table.insert(args, b.effort) end

  local final
  return spawn(bin, args, function(line)
    local ev = U.decode(line)
    if not ev then return end
    if ev.type == "stream_event" then
      local e = ev.event or {}
      if e.type == "content_block_delta" and e.delta and e.delta.type == "text_delta" then out.delta(e.delta.text) end
    elseif ev.type == "result" then
      final = ev
    end
  end, function(code, err)
    if final and final.is_error then return out.done(tostring(final.result)) end
    if code ~= 0 then return out.done(exitError(code, err)) end
    out.done(nil, final and type(final.result) == "string" and final.result ~= "" and final.result or nil)
  end)
end

function runners.codex(b, system, prompt, out)
  local bin = findBinary(b, "codex")
  if not bin then return out.done("找不到 codex 命令，请在设置里填写可执行文件路径") end
  -- 只读沙箱、不落会话、在临时目录里跑，避免读到项目里的 AGENTS.md
  local args = {
    "exec", "--json", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only",
    "-C", os.getenv("TMPDIR") or "/tmp",
  }
  if not U.isAuto(b.model) then table.insert(args, "-m"); table.insert(args, b.model) end
  if not U.isAuto(b.effort) then
    table.insert(args, "-c"); table.insert(args, ('model_reasoning_effort="%s"'):format(b.effort))
  end
  -- codex 没有单独的系统提示参数，拼在前面；以中文开头，不会被当成命令行选项
  table.insert(args, system .. "\n\n" .. prompt)

  local n, errMsg = 0, nil
  return spawn(bin, args, function(line)
    local ev = U.decode(line)
    if not ev then return end
    local item = ev.item
    if ev.type == "item.completed" and item and type(item.text) == "string"
        and (item.type == "agent_message" or item.type == "assistant_message") then
      n = n + 1
      out.delta((n > 1 and "\n\n" or "") .. item.text)
    elseif ev.type == "turn.failed" or ev.type == "error" then
      errMsg = (type(ev.error) == "table" and ev.error.message) or ev.message or line
    end
  end, function(code, err)
    if code ~= 0 or (n == 0 and errMsg) then return out.done(errMsg or exitError(code, err)) end
    out.done(nil)
  end)
end

function runners.command(b, system, prompt, out)
  local parts = U.splitArgs(b.line or "")
  if #parts == 0 then return out.done("请在设置里填写命令") end
  local bin = findBinary({}, parts[1])
  if not bin then return out.done("找不到命令 " .. parts[1]) end
  local full = system .. "\n\n" .. prompt
  local args, used = {}, false
  for i = 2, #parts do
    if parts[i]:find("{prompt}", 1, true) then used = true end
    args[#args + 1] = parts[i]:gsub("{prompt}", function() return full end)
  end
  if not used then args[#args + 1] = full end
  return spawn(bin, args, out.delta, function(code, err)
    if code ~= 0 then return out.done(exitError(code, err)) end
    out.done(nil)
  end, true)
end

local OFFICIAL = { openai = "api.openai.com", anthropic = "api.anthropic.com" }

local function needsKey(p, host, key)
  return not key and host:find(OFFICIAL[p], 1, true)
end

function runners.openai(b, system, prompt, out)
  local host = orDefault(b.host, "https://api.openai.com/v1")
  local key = getKey(b.id)
  if needsKey("openai", host, key) then return out.done("还没有设置 OpenAI 的 API Key") end
  local url = apiUrl(host, "/chat/completions")
  local headers = { "content-type: application/json" }
  if key then headers[#headers + 1] = "authorization: Bearer " .. key end
  local body = {
    model = b.model, stream = true,
    messages = { { role = "system", content = system }, { role = "user", content = prompt } },
  }
  if not U.isAuto(b.effort) then body.reasoning_effort = b.effort end

  local errMsg
  return curlStream(url, headers, body, function(ev)
    if ev.error then
      errMsg = type(ev.error) == "table" and ev.error.message or tostring(ev.error)
      return
    end
    local c = ev.choices and ev.choices[1]
    local t = c and c.delta and c.delta.content
    if type(t) == "string" then out.delta(t) end
  end, function(msg) out.done(errMsg or msg) end)
end

function runners.anthropic(b, system, prompt, out)
  local host = orDefault(b.host, "https://api.anthropic.com")
  local key = getKey(b.id)
  if needsKey("anthropic", host, key) then return out.done("还没有设置 Anthropic 的 API Key") end
  local url = apiUrl(host, "/messages")
  local headers = { "content-type: application/json", "anthropic-version: 2026-10-21" }
  if key then headers[#headers + 1] = "x-api-key: " .. key end
  local body = {
    model = b.model, max_tokens = 64000, stream = true,
    system = system, messages = { { role = "user", content = prompt } },
  }
  if not U.isAuto(b.effort) then body.output_config = { effort = b.effort } end
  -- 拒答时服务端自动换模型重试；Haiku 没有这个能力，跳过
  if b.fallbacks and not tostring(b.model):find("haiku") then
    body.fallbacks = "default"
    headers[#headers + 1] = "anthropic-beta: server-side-fallback-2026-07-01"
  end

  local errMsg, refused = nil, false
  return curlStream(url, headers, body, function(ev)
    if ev.type == "content_block_delta" and ev.delta and ev.delta.type == "text_delta" then
      out.delta(ev.delta.text)
    elseif ev.type == "content_block_start" and ev.content_block and ev.content_block.type == "fallback" then
      out.reset() -- 换了模型重来，丢掉上一个模型的半截输出
    elseif ev.type == "message_delta" and ev.delta and ev.delta.stop_reason then
      refused = ev.delta.stop_reason == "refusal"
    elseif ev.type == "error" then
      errMsg = type(ev.error) == "table" and ev.error.message or "请求出错"
    end
  end, function(msg)
    if not (errMsg or msg) and refused then
      out.reset()
      return out.done("模型拒绝回答这段内容")
    end
    out.done(errMsg or msg)
  end)
end

---------------------------------------------------------------------------

function B.run(profile, system, prompt, out)
  local run = runners[profile.provider]
  if not run then return out.done("不认识的模型来源：" .. tostring(profile.provider)) end
  if (profile.provider == "openai" or profile.provider == "anthropic") and U.isAuto(profile.model) then
    return out.done("请在设置里填写模型")
  end
  return run(profile, system, prompt, out)
end

local TEST_PROMPT = "上下文：It was pure serendipity that we met on the train.\n要查的词：serendipity"

-- 用示例单词跑一次，回报 { ok, error, ttft, total（毫秒）, sample }
function B.test(profile, cb)
  local t0 = hs.timer.absoluteTime()
  local ms = function() return math.floor((hs.timer.absoluteTime() - t0) / 1e6) end
  local text, ttft = "", nil
  local t
  t = B.run(profile, config.prompt(), TEST_PROMPT, {
    delta = function(s)
      ttft = ttft or ms()
      text = text .. s
    end,
    reset = function() text = "" end,
    done = function(err, final)
      if t then tasks[t] = nil end
      if final then text = final end
      local ok = not err and text:find("%S") ~= nil
      cb({
        ok = ok, error = err or (not ok and "没有返回内容" or nil),
        ttft = ttft or ms(), total = ms(),
        sample = U.utf8Head(U.trim(text):match("^[^\n]*") or "", 80),
      })
    end,
  })
  if t then tasks[t] = true end
  return t
end

-- 比如「Claude Code · sonnet」
function B.describe(profile)
  local name = B.NAMES[profile.provider] or profile.provider
  if profile.provider == "command" then return name end
  return U.isAuto(profile.model) and name or (name .. " · " .. profile.model)
end

return B
