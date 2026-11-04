-- 设置面板：普通窗口里的网页，改动立即保存进 hs.settings 并生效

local config = require("llm_lookup.config")
local backends = require("llm_lookup.backends")
local U = require("llm_lookup.util")

local S = {}

-- 由 init 设置：onChange(key) / onProfilesChanged() / onHotkey(mods, key) -> ok, err / onRecording(on)
S.hooks = {}

local wv, uc, ready, queue = nil, nil, false, {}

local function js(fn, arg)
  if not wv then return end
  local call = fn .. "(" .. hs.json.encode({ arg }) .. "[0])"
  if ready then wv:evaluateJavaScript(call) else queue[#queue + 1] = call end
end

local function state()
  local v = config.values
  local keys = {}
  for _, p in ipairs(v.profiles) do
    if p.provider == "openai" or p.provider == "anthropic" then keys[p.id] = backends.hasKey(p.id) end
  end
  local tap = hs.execute("defaults read com.apple.AppleMultitouchTrackpad TrackpadThreeFingerTapGesture 2>/dev/null")
  return {
    profiles = v.profiles, active = v.active, keys = keys,
    detected = { claude = backends.detected("claude") or "", codex = backends.detected("codex") or "" },
    hotkey = v.hotkey, threeFingerTap = v.threeFingerTap, doubleClickFallback = v.doubleClickFallback,
    width = v.width, maxHeight = v.maxHeight, prompt = config.prompt(),
    systemLookupOn = U.trim(tap or "") == "2",
    axTrusted = hs.accessibilityState(),
  }
end

-- 页面能改的项和类型，其它一律忽略
local SETTINGS = { threeFingerTap = "boolean", doubleClickFallback = "boolean", width = "number", maxHeight = "number", prompt = "string" }
local RANGES = { width = { 360, 640 }, maxHeight = { 320, 800 } }
local PROFILE_FIELDS = {
  name = "string", provider = "string", model = "string", effort = "string",
  path = "string", line = "string", host = "string", fallbacks = "boolean",
}
local MODS = { ctrl = true, alt = true, shift = true, cmd = true }

local function profilesChanged()
  if S.hooks.onProfilesChanged then S.hooks.onProfilesChanged() end
end

local handlers = {}

function handlers.ready()
  ready = true
  for _, call in ipairs(queue) do wv:evaluateJavaScript(call) end
  queue = {}
  js("load", state())
end

function handlers.set(m)
  local kind = SETTINGS[m.key]
  if not kind or type(m.value) ~= kind then return end
  local value = m.value
  if RANGES[m.key] then value = math.max(RANGES[m.key][1], math.min(RANGES[m.key][2], value)) end
  if m.key == "prompt" and U.trim(value) == U.trim(config.DEFAULT_PROMPT) then value = "" end
  config.set(m.key, value)
  if S.hooks.onChange then S.hooks.onChange(m.key) end
end

function handlers.use(m)
  config.setActive(m.id)
  profilesChanged()
end

function handlers.addProfile()
  local p = config.addProfile()
  profilesChanged()
  js("load", state())
  js("edit", p.id)
end

function handlers.removeProfile(m)
  if config.removeProfile(m.id) then
    backends.removeKey(m.id)
    profilesChanged()
    js("load", state())
  end
end

function handlers.updateProfile(m)
  local kind = PROFILE_FIELDS[m.field]
  if not kind or type(m.value) ~= kind then return end
  if config.updateProfile(m.id, m.field, m.value) then
    profilesChanged()
    -- 换来源会重置参数，整个面板刷新；其它字段页面上已经是新值了
    if m.field == "provider" then js("load", state()) end
  end
end

function handlers.test(m)
  local p = config.find(m.id)
  if not p then return end
  backends.test(p, function(r)
    r.id = m.id
    js("testResult", r)
  end)
end

function handlers.apikey(m)
  if not config.find(m.id) then return end
  backends.setKey(m.id, m.value, function(ok) js("keySaved", { id = m.id, has = ok }) end)
end

function handlers.apikeyRemove(m)
  backends.removeKey(m.id)
  js("keySaved", { id = m.id, has = false, removed = true })
end

function handlers.hotkey(m)
  local mods = {}
  for _, k in ipairs(type(m.mods) == "table" and m.mods or {}) do
    if MODS[k] then mods[#mods + 1] = k end
  end
  local ok, err = false, "这个快捷键用不了"
  if type(m.key) == "string" and #m.key <= 8 then ok, err = S.hooks.onHotkey(mods, m.key) end
  js("hotkeyResult", { ok = ok, error = err, hotkey = config.values.hotkey })
end

function handlers.recording(m)
  if S.hooks.onRecording then S.hooks.onRecording(m.on == true) end
end

function handlers.resetPrompt()
  config.set("prompt", "")
  js("load", state())
end

-- Hammerspoon 没有「编辑」菜单，页面里的复制粘贴走这里
function handlers.paste() js("pasteText", hs.pasteboard.getContents() or "") end
function handlers.copy(m) if type(m.text) == "string" then hs.pasteboard.setContents(m.text) end end

function handlers.openAX()
  hs.execute([[open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]])
end

function handlers.openTrackpad()
  hs.execute([[open "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"]])
end

function handlers.close() S.close() end

function S.open()
  if wv then
    wv:show()
    hs.focus()
    local win = wv:hswindow()
    if win then win:focus() end
    return
  end
  ready, queue = false, {}
  uc = hs.webview.usercontent.new("settings")
  uc:setCallback(function(msg)
    local m = msg.body or {}
    local h = handlers[m.type]
    if h then h(m) end
  end)
  local sf = hs.screen.mainScreen():frame()
  local w, h = 620, math.min(860, sf.h - 60)
  wv = hs.webview.new({ x = sf.x + (sf.w - w) / 2, y = sf.y + (sf.h - h) / 2, w = w, h = h }, {}, uc)
      :windowStyle({ "titled", "closable", "miniaturizable" })
      :windowTitle("划词查词")
      :allowTextEntry(true)
      :deleteOnClose(true)
      :windowCallback(function(action)
        if action == "closing" then
          wv, ready = nil, false
          if S.hooks.onRecording then S.hooks.onRecording(false) end
        end
      end)
      :html(U.readFile("settings.html"))
  wv:show()
  -- 激活 Hammerspoon，输入框才能接收键盘
  hs.focus()
  local win = wv:hswindow()
  if win then win:focus() end
end

function S.close()
  if wv then wv:delete() end
  wv, ready = nil, false
  if S.hooks.onRecording then S.hooks.onRecording(false) end
end

-- 菜单栏等其它地方改了配置，同步到打开着的面板
function S.refresh()
  if wv and ready then js("load", state()) end
end

return S
