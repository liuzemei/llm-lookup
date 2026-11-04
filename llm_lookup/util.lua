local U = {}

U.dir = debug.getinfo(1, "S").source:match("^@(.*/)")

function U.readFile(name)
  local f = assert(io.open(U.dir .. name, "r"))
  local s = f:read("a")
  f:close()
  return s
end

-- hs.timer 对象没人引用会被 GC 掉，统一挂在这里
local timers = {}
function U.after(sec, fn)
  local t
  t = hs.timer.doAfter(sec, function()
    timers[t] = nil
    fn()
  end)
  timers[t] = true
  return t
end

function U.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function U.utf8Head(s, n)
  local i = utf8.offset(s, n + 1)
  return i and s:sub(1, i - 1) or s
end

function U.utf8Tail(s, n)
  local len = utf8.len(s)
  if not len or len <= n then return s end
  return s:sub(utf8.offset(s, len - n + 1))
end

function U.isAuto(v) return v == nil or v == "" or v == "auto" end

function U.shellQuote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

function U.decode(s)
  -- 先看像不像 JSON：hs.json.decode 解析失败会往控制台打一条错误
  if type(s) ~= "string" or not s:find("^%s*[%[{]") then return nil end
  local ok, v = pcall(hs.json.decode, s)
  return ok and type(v) == "table" and v or nil
end

function U.errTail(s)
  return U.utf8Tail(U.trim(s or ""), 300)
end

-- 带引号的简单命令行切分：gemini -p "{prompt}" → { "gemini", "-p", "{prompt}" }
function U.splitArgs(s)
  local args, cur, quote = {}, nil, nil
  for ch in s:gmatch(utf8.charpattern) do
    if quote then
      if ch == quote then quote = nil else cur = cur .. ch end
    elseif ch == '"' or ch == "'" then
      quote, cur = ch, cur or ""
    elseif ch:match("^%s$") then
      if cur then args[#args + 1], cur = cur, nil end
    else
      cur = (cur or "") .. ch
    end
  end
  if cur then args[#args + 1] = cur end
  return args
end

return U
