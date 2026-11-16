-- 历史记录：浮窗里的对话每次有了回答就存一份，新的在前，最多留 MAX 条
-- 存在 ~/Library/Application Support/llm-lookup/history.json，不放代码目录（那里常是软链接到 git 仓库）
--
-- 每条：{ id, kind = "lookup"|"ask", title, profile, created, updated（秒）, messages = { {role, content}, ... } }
-- 查词那条的第一条用户消息是拼好的提示词，界面上按原文显示

local H = {}

local DIR = os.getenv("HOME") .. "/Library/Application Support/llm-lookup"
local FILE = DIR .. "/history.json"
local MAX = 500

H.onChange = nil -- 由 init 设置：记录有变化时刷新打开着的历史窗口

local log = hs.logger.new("llmLookup", "info")
local items

local function load()
  if items then return items end
  items = {}
  local f = io.open(FILE, "r")
  if f then
    local s = f:read("a")
    f:close()
    local ok, v = pcall(hs.json.decode, s)
    if ok and type(v) == "table" then items = v else log.w("历史记录读不出来，从空的开始") end
  end
  return items
end

-- 先写临时文件再改名，写到一半退出也不会把原来的弄坏
local function write()
  hs.fs.mkdir(DIR)
  local ok, s = pcall(hs.json.encode, items)
  if not ok then return log.e("历史记录编码失败：" .. tostring(s)) end
  local tmp = FILE .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return log.e("历史记录写不进 " .. DIR) end
  f:write(s)
  f:close()
  os.rename(tmp, FILE)
  if H.onChange then H.onChange() end
end

function H.list() return load() end

function H.get(id)
  for _, r in ipairs(load()) do
    if r.id == id then return r end
  end
end

-- 存一段对话。同一个 record 表再存就是更新这一条，并挪到最前面
function H.save(record, messages)
  local list = load()
  local now = os.time()
  if not record.id then
    record.id = ("%d%03d"):format(now, math.random(0, 999))
    record.created = now
  end
  record.updated = now
  local copy = {}
  for i, m in ipairs(messages) do copy[i] = { role = m.role, content = m.content } end
  record.messages = copy
  for i, r in ipairs(list) do
    if r.id == record.id then
      table.remove(list, i)
      break
    end
  end
  table.insert(list, 1, record)
  while #list > MAX do table.remove(list) end
  write()
end

function H.remove(id)
  local list = load()
  for i, r in ipairs(list) do
    if r.id == id then
      table.remove(list, i)
      return write()
    end
  end
end

function H.clear()
  items = {}
  write()
end

return H
