-- 模型来源：本机 Claude Code / Codex / 任意命令行，或 OpenAI / Anthropic 格式的 HTTP 接口
--
-- 每个 runner(b, system, messages, out, opts) 通过 out.delta(text) / out.reset() / out.done(err, finalText) 回报，
-- 可选的 out.status(text) 报告「正在联网搜索」这类进度；opts.search 为 true 时允许模型联网搜索（命令行来源不支持）。
-- 返回 hs.task 或有 isRunning / terminate 的对象（用于取消）；出错时可以直接 out.done(err) 并返回 nil

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

-- 多轮对话：messages 是 { {role = "user"|"assistant", content = ...}, ... }，也兼容只传一个字符串
local function asMessages(m)
  if type(m) == "string" then return { { role = "user", content = m } } end
  return m
end

-- 命令行来源只能收一段文字，把历史拼进去。只有一轮时原样返回
local function flatten(messages)
  if #messages == 1 then return messages[1].content end
  local parts = { "下面是我们之前的对话，请接着回答我最后的追问。" }
  for i, m in ipairs(messages) do
    local who = m.role == "assistant" and "【你的回答】" or (i == #messages and "【我的追问】" or "【我】")
    parts[#parts + 1] = who .. "\n" .. m.content
  end
  return table.concat(parts, "\n\n")
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

local function searching(out)
  if out.status then out.status("正在联网搜索…") end
end

-- 搜索前后的文字是两段（「我查一下」…搜索…「查到的是」），接起来时中间空一行。
-- 返回 text(t) 输出文字，tool() 在每次调用工具时调
local function paragraphs(out)
  local any, broken = false, false
  return function(t)
    if broken and any then t = "\n\n" .. t end
    any, broken = true, false
    out.delta(t)
  end, function() broken = true end
end

function runners.claude(b, system, messages, out, opts)
  local prompt = flatten(messages)
  -- 以 - 开头会被当成命令行选项（问答框里可能直接问「--force 是什么」），前面垫个空格
  if prompt:find("^%-") then prompt = " " .. prompt end
  local bin = findBinary(b, "claude")
  if not bin then return out.done("找不到 claude 命令，请在设置里填写可执行文件路径") end
  local args = {
    "-p", prompt, "--system-prompt", system,
    "--output-format", "stream-json", "--include-partial-messages", "--verbose",
    -- 纯问答：不加载 MCP、设置、斜杠命令，也不落会话记录，启动最快；工具只在联网时开 WebSearch
    "--tools", opts.search and "WebSearch" or "", "--setting-sources", "", "--strict-mcp-config",
    "--disable-slash-commands", "--no-session-persistence",
  }
  -- -p 模式没人点「允许」，要预先放行
  if opts.search then table.insert(args, "--allowedTools"); table.insert(args, "WebSearch") end
  if not U.isAuto(b.model) then table.insert(args, "--model"); table.insert(args, b.model) end
  if not U.isAuto(b.effort) then table.insert(args, "--effort"); table.insert(args, b.effort) end

  local final
  local text, tool = paragraphs(out)
  return spawn(bin, args, function(line)
    local ev = U.decode(line)
    if not ev or ev.parent_tool_use_id then return end -- 工具内部的事件不算回答
    if ev.type == "stream_event" then
      local e = ev.event or {}
      if e.type == "content_block_delta" and e.delta and e.delta.type == "text_delta" then
        text(e.delta.text)
      elseif e.type == "content_block_start" and e.content_block and e.content_block.type == "tool_use" then
        tool()
        searching(out)
      end
    elseif ev.type == "result" then
      final = ev
    end
  end, function(code, err)
    if final and final.is_error then return out.done(tostring(final.result)) end
    if code ~= 0 then return out.done(exitError(code, err)) end
    out.done(nil, final and type(final.result) == "string" and final.result ~= "" and final.result or nil)
  end)
end

function runners.codex(b, system, messages, out, opts)
  local prompt = flatten(messages)
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
  -- live 是实时联网；不联网时不传，沿用 Codex 自己的设置
  if opts.search then table.insert(args, "-c"); table.insert(args, 'web_search="live"') end
  -- codex 没有单独的系统提示参数，拼在前面；以中文开头，不会被当成命令行选项
  table.insert(args, system .. "\n\n" .. prompt)

  local n, errMsg = 0, nil
  return spawn(bin, args, function(line)
    local ev = U.decode(line)
    if not ev then return end
    local item = ev.item
    if ev.type == "item.started" and item and item.type == "web_search" then
      searching(out)
    elseif ev.type == "item.completed" and item and type(item.text) == "string"
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

function runners.command(b, system, messages, out)
  local prompt = flatten(messages)
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

local function openaiChat(b, host, headers, system, messages, out)
  local body = {
    model = b.model, stream = true,
    messages = { { role = "system", content = system }, table.unpack(messages) },
  }
  if not U.isAuto(b.effort) then body.reasoning_effort = b.effort end

  local errMsg
  return curlStream(apiUrl(host, "/chat/completions"), headers, body, function(ev)
    if ev.error then
      errMsg = type(ev.error) == "table" and ev.error.message or tostring(ev.error)
      return
    end
    local c = ev.choices and ev.choices[1]
    local t = c and c.delta and c.delta.content
    if type(t) == "string" then out.delta(t) end
  end, function(msg) out.done(errMsg or msg) end)
end

-- Chat Completions 不能联网，联网走 Responses 接口的 web_search 工具
local function openaiSearch(b, host, headers, system, messages, out)
  local body = {
    model = b.model, stream = true, instructions = system, input = messages,
    tools = { { type = "web_search" } },
  }
  -- 最低思考强度不能配联网搜索，至少用 low
  if not U.isAuto(b.effort) then body.reasoning = { effort = b.effort == "minimal" and "low" or b.effort } end

  local errMsg
  local text, tool = paragraphs(out)
  return curlStream(apiUrl(host, "/responses"), headers, body, function(ev)
    if ev.type == "response.output_text.delta" and type(ev.delta) == "string" then
      text(ev.delta)
    -- 官方接口发 web_search_call 系列事件；有的中转站只发一段 function_call 参数（里面是搜索词）
    elseif tostring(ev.type):find("web_search_call", 1, true) or ev.type == "response.function_call_arguments.delta"
        or (ev.type == "response.output_item.added" and ev.item and ev.item.type == "web_search_call") then
      tool()
      searching(out)
    elseif ev.type == "response.failed" then
      local e = ev.response and ev.response.error
      errMsg = type(e) == "table" and e.message or "请求失败"
    elseif ev.type == "error" then
      errMsg = ev.message or (type(ev.error) == "table" and ev.error.message) or "请求出错"
    end
  end, function(msg) out.done(errMsg or msg) end)
end

function runners.openai(b, system, messages, out, opts)
  local host = orDefault(b.host, "https://api.openai.com/v1")
  local key = getKey(b.id)
  if needsKey("openai", host, key) then return out.done("还没有设置 OpenAI 的 API Key") end
  local headers = { "content-type: application/json" }
  if key then headers[#headers + 1] = "authorization: Bearer " .. key end
  if not opts.search then return openaiChat(b, host, headers, system, messages, out) end

  -- 很多兼容接口没有 /responses 或不支持联网：还没出字就失败的话，注明一句改走普通对话
  local cur, wrote = nil, false
  cur = openaiSearch(b, host, headers, system, messages, {
    delta = function(t) wrote = true; out.delta(t) end,
    reset = out.reset, status = out.status,
    done = function(err, final)
      if not err or wrote then return out.done(err, final) end
      out.delta(("> 联网搜索没成功（%s），下面直接回答。\n\n"):format(U.utf8Head((U.trim(err):gsub("%s+", " ")), 80)))
      cur = openaiChat(b, host, headers, system, messages, out)
    end,
  })
  return {
    isRunning = function() return cur ~= nil and cur:isRunning() end,
    terminate = function() if cur then cur:terminate() end end,
  }
end

function runners.anthropic(b, system, messages, out, opts)
  local host = orDefault(b.host, "https://api.anthropic.com")
  local key = getKey(b.id)
  if needsKey("anthropic", host, key) then return out.done("还没有设置 Anthropic 的 API Key") end
  local url = apiUrl(host, "/messages")
  local headers = { "content-type: application/json", "anthropic-version: 2026-10-21" }
  if key then headers[#headers + 1] = "x-api-key: " .. key end
  local body = {
    model = b.model, max_tokens = 64000, stream = true,
    system = system, messages = messages,
  }
  if not U.isAuto(b.effort) then body.output_config = { effort = b.effort } end
  -- 拒答时服务端自动换模型重试；Haiku 没有这个能力，跳过
  if b.fallbacks and not tostring(b.model):find("haiku") then
    body.fallbacks = "default"
    headers[#headers + 1] = "anthropic-beta: server-side-fallback-2026-07-01"
  end
  -- 用基础版搜索：带动态过滤的新版要先跑代码筛结果，浮窗问答要的是快；Haiku 和旧模型也都支持基础版
  if opts.search then body.tools = { { type = "web_search_20250305", name = "web_search", max_uses = 5 } } end

  local errMsg, refused = nil, false
  local text, tool = paragraphs(out)
  return curlStream(url, headers, body, function(ev)
    if ev.type == "content_block_delta" and ev.delta and ev.delta.type == "text_delta" then
      text(ev.delta.text)
    elseif ev.type == "content_block_start" and ev.content_block and ev.content_block.type == "server_tool_use" then
      tool()
      searching(out)
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

-- opts.search：允许联网搜索
function B.run(profile, system, messages, out, opts)
  local run = runners[profile.provider]
  if not run then return out.done("不认识的模型来源：" .. tostring(profile.provider)) end
  if (profile.provider == "openai" or profile.provider == "anthropic") and U.isAuto(profile.model) then
    return out.done("请在设置里填写模型")
  end
  return run(profile, system, asMessages(messages), out, opts or {})
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
