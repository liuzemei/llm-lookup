-- 配置：代码里只放默认值，用户在设置面板里的改动存进 hs.settings（Hammerspoon 的偏好设置）
--
-- 模型配置（profiles）可以有多套，每套是一个来源（provider）加上它的参数；active 是当前用的那套

local C = {}

C.DEFAULT_PROMPT = [[
你是 macOS 上的划词翻译与解析助手。用户会给你一段他在屏幕上选中或指向的文字，你直接输出结果：不寒暄，不复述任务，不加结尾总结。默认用简体中文解释；如果原文本身是中文，就给出英文翻译、用中文解释。输出 Markdown，尽量紧凑。

按内容类型输出：
1. 单词或短语：第一行 **原词** /音标/ 词性（中文词给拼音）；然后列出常用释义（最多 4 条），如果给了上下文，把上下文中的含义放第一条并标注「（此处）」；再给 1–2 个地道例句，每句附中文翻译；有价值时补一行词源/构词或易混词，没有就省略。
2. 句子或段落：先给出通顺自然的译文；然后写「**解析**」，列出 2–5 个难点词汇、短语或习语并附释义，必要时用一两句话说明句子结构；简单句子省略解析。
3. 代码、报错信息、术语或缩写：说明它是什么、什么意思、常见用法。

单词控制在 150 字以内，句子控制在 400 字以内。]]

C.PROVIDER_NAMES = { claude = "Claude Code", codex = "Codex", command = "命令行", openai = "OpenAI", anthropic = "Anthropic" }

-- 每种来源的参数和默认值；model / effort 留空表示用对方的默认值；API Key 不在这里，存在钥匙串里
C.PROVIDER_DEFAULTS = {
  claude = { model = "sonnet", effort = "", path = "" },
  codex = { model = "", effort = "", path = "" },
  command = { line = "gemini -p {prompt}" },
  openai = { host = "https://api.openai.com/v1", model = "gpt-5.5", effort = "" },
  anthropic = { host = "https://api.anthropic.com", model = "claude-opus-5-5", effort = "", fallbacks = true },
}

local DEFAULTS = {
  profiles = {
    { id = "claude", name = "Claude Code", provider = "claude", model = "sonnet", effort = "", path = "" },
    { id = "codex", name = "Codex", provider = "codex", model = "", effort = "", path = "" },
  },
  active = "claude",
  hotkey = { mods = { "alt" }, key = "r" },
  threeFingerTap = true,
  doubleClickFallback = true, -- 只在按快捷键时用：读不到文字就模拟双击选词
  enableChromiumAX = true,    -- 给 Electron 应用打开辅助功能树，才能读到里面的文字
  width = 460,
  maxHeight = 560,
  prompt = "",                -- 空 = 用 DEFAULT_PROMPT
}

local KEY = "llmLookup.config"

local function copy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = copy(v) end
  return r
end

-- 字典递归合并，数组整体替换
local function merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" and #v == 0 and next(v) ~= nil then
      merge(dst[k], v)
    else
      dst[k] = copy(v)
    end
  end
  return dst
end

-- 旧版只有「每种来源一份设置」（provider + backends），转成配置列表
local function migrate(saved)
  if saved.profiles or type(saved.backends) ~= "table" then return saved end
  local profiles = copy(DEFAULTS.profiles)
  for _, p in ipairs(profiles) do merge(p, saved.backends[p.provider] or {}) end
  local active = saved.provider or "claude"
  if active ~= "claude" and active ~= "codex" and C.PROVIDER_DEFAULTS[active] then
    local p = merge(copy(C.PROVIDER_DEFAULTS[active]), saved.backends[active] or {})
    p.id, p.name, p.provider = active, C.PROVIDER_NAMES[active], active
    profiles[#profiles + 1] = p
  end
  saved.profiles, saved.active, saved.provider, saved.backends = profiles, active, nil, nil
  return saved
end

function C.load()
  local saved = hs.settings.get(KEY)
  saved = type(saved) == "table" and migrate(saved) or {}
  C.values = merge(copy(DEFAULTS), saved)
  if not C.find(C.values.active) then C.values.active = C.values.profiles[1].id end
  return C.values
end

function C.save()
  hs.settings.set(KEY, C.values)
end

function C.set(key, value)
  C.values[key] = value
  C.save()
end

function C.prompt()
  local p = C.values.prompt
  return (type(p) == "string" and p:find("%S")) and p or C.DEFAULT_PROMPT
end

---------------------------------------------------------------------------
-- 模型配置
---------------------------------------------------------------------------

function C.find(id)
  for i, p in ipairs(C.values.profiles) do
    if p.id == id then return p, i end
  end
end

function C.active()
  return C.find(C.values.active) or C.values.profiles[1]
end

function C.setActive(id)
  if C.find(id) then C.set("active", id) end
end

function C.addProfile()
  local p = copy(C.PROVIDER_DEFAULTS.openai)
  p.id = ("p%d%03d"):format(os.time(), math.random(0, 999))
  p.name, p.provider = "新配置", "openai"
  table.insert(C.values.profiles, p)
  C.save()
  return p
end

function C.removeProfile(id)
  local _, i = C.find(id)
  if not i or #C.values.profiles <= 1 then return false end
  table.remove(C.values.profiles, i)
  if C.values.active == id then C.values.active = C.values.profiles[1].id end
  C.save()
  return true
end

-- 改配置里的一项；换来源时把参数换成新来源的默认值，名字没改过的话跟着换
function C.updateProfile(id, field, value)
  local p = C.find(id)
  if not p then return end
  if field == "provider" then
    local defaults = C.PROVIDER_DEFAULTS[value]
    if not defaults or value == p.provider then return end
    if p.name == C.PROVIDER_NAMES[p.provider] or p.name == "新配置" then p.name = C.PROVIDER_NAMES[value] end
    for k in pairs(C.PROVIDER_DEFAULTS[p.provider] or {}) do p[k] = nil end
    for k, v in pairs(defaults) do p[k] = v end
    p.provider = value
  elseif field == "model" or field == "host" then
    -- 这几项里不会有空白和 '（拼音输入法在音节间插的分隔符）
    p[field] = (value:gsub("[%s']", ""))
  else
    p[field] = value
  end
  C.save()
  return p
end

C.load()
return C
