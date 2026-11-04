-- 划词 / 三指轻点 → LLM 翻译解析浮窗
--
--   快捷键（默认 ⌥R） 有选中文字就查选中的，没有就查鼠标指着的词
--   三指轻点          同上（需要在 系统设置 › 触控板 关掉「查询与数据检测器」）
--   菜单栏图标        切换模型配置、打开设置面板；配置都存在 Hammerspoon 的偏好设置里
--   打开 App          直接是设置面板（App 文件夹改名成了「划词查词.app」）

local config = require("llm_lookup.config")
local U = require("llm_lookup.util")
local capture = require("llm_lookup.capture")
local backends = require("llm_lookup.backends")
local popup = require("llm_lookup.popup")
local settings = require("llm_lookup.settings")

local M = {}

local log = hs.logger.new("llmLookup", "info")

---------------------------------------------------------------------------
-- 查词
---------------------------------------------------------------------------

local gen, task = 0, nil

-- 浮窗关掉（Esc、点外面、开始新的查询）时作废正在跑的请求
popup.onClose = function()
  gen = gen + 1
  if task and task:isRunning() then task:terminate() end
  task = nil
end

local function show(q, pos)
  local prompt, title = capture.buildPrompt(q)
  local profile = config.active()
  popup.show(pos, title, profile.name)

  gen = gen + 1
  local mine = gen
  local text, shown, pending = "", nil, false
  local function flush()
    pending = false
    if mine == gen and text ~= shown then
      shown = text
      popup.render(text)
    end
  end
  local function schedule()
    if not pending then
      pending = true
      U.after(0.05, flush)
    end
  end
  task = backends.run(profile, config.prompt(), prompt, {
    delta = function(t)
      if mine ~= gen then return end
      text = text .. t
      schedule()
    end,
    reset = function()
      if mine ~= gen then return end
      text = ""
      schedule()
    end,
    done = function(err, final)
      if mine ~= gen then return end
      if final then text = final end
      flush()
      if err then
        popup.fail(err)
      elseif text == "" then
        popup.fail("没有返回内容")
      end
      popup.finish()
    end,
  })
end

function M.lookup(source)
  local fromTap = source == "tap"
  local snap = fromTap and M.snap
  if snap and hs.timer.secondsSinceEpoch() - snap.t > 1.5 then snap = nil end
  local pos = snap and snap.pos or hs.mouse.absolutePosition()
  popup.close()
  local mine = gen
  local front = hs.application.frontmostApplication()
  capture.acquire(snap and snap.sel, pos, function(q, why)
    -- 只记来源和取词方式，不记内容，方便查「为什么取不到」
    log.i(("%s · %s · %s"):format(source, front and front:name() or "?",
      q and (q.via .. "/" .. q.kind) or ("没取到：" .. tostring(why))))
    if mine ~= gen then return end
    if not q then
      -- 三指轻点读不到就静默放弃，只有主动按快捷键才提示
      if not fromTap then hs.alert.show("没有取到文字", 1) end
      return
    end
    show(q, pos)
  end)
end

function M.lookupText(text)
  popup.close()
  show({ kind = "selection", text = text }, hs.mouse.absolutePosition())
end

---------------------------------------------------------------------------
-- 三指轻点：由独立的 tapwatch 进程检测（见 tapwatch.c），这里只读它的输出。
-- 不用 hs.eventtap 监听手势，因为那样每一帧触点都要等 Lua 处理完才放行，拖动和滚动会卡
---------------------------------------------------------------------------

local TAPWATCH = U.dir .. "bin/tapwatch"
local watcher, watcherGen, restarts = nil, 0, 0

local function onTapLine(line)
  if line == "down" then
    -- 手指一落下就先记下选区（第二、第三根落下时各通知一次）：开着「三指拖移」时系统可能一碰到就发鼠标按下，
    -- 终端、编辑器会立刻清掉选区；第三根落下时已经读不到的话，保留第二根时记下的
    local now = hs.timer.secondsSinceEpoch()
    local ok, sel = pcall(capture.selectedText)
    sel = ok and sel or nil
    if not sel and M.snap and M.snap.sel and now - M.snap.t < 0.5 then return end
    M.snap = { t = now, pos = hs.mouse.absolutePosition(), sel = sel }
  elseif line == "tap" then
    M.lookup("tap")
  end
end

local startWatcher

local function launchWatcher()
  watcherGen = watcherGen + 1
  local mine, started, buf = watcherGen, hs.timer.secondsSinceEpoch(), ""
  watcher = hs.task.new(TAPWATCH, function(code, _, err)
    if mine ~= watcherGen then return end -- 是我们自己停掉的
    watcher = nil
    log.w("tapwatch 退出 " .. tostring(code) .. " " .. U.errTail(err))
    -- 意外退出就重启；刚启动就崩的话最多试 3 次，免得一直刷
    if hs.timer.secondsSinceEpoch() - started > 10 then restarts = 0 end
    restarts = restarts + 1
    if config.values.threeFingerTap and restarts <= 3 then U.after(2 * restarts, startWatcher) end
  end, function(_, out)
    buf = buf .. (out or "")
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then break end
      onTapLine(buf:sub(1, nl - 1))
      buf = buf:sub(nl + 1)
    end
    return true
  end, {})
  watcher:start()
end

-- 二进制不在就用源码现编一个（需要 Xcode 命令行工具）
startWatcher = function()
  if watcher then return end
  if hs.fs.attributes(TAPWATCH) then return launchWatcher() end
  hs.fs.mkdir(U.dir .. "bin")
  local t
  t = hs.task.new("/usr/bin/clang", function(code, _, err)
    M._build = nil
    if code == 0 then launchWatcher() else log.e("编译 tapwatch 失败：" .. U.errTail(err)) end
  end, { "-O2", "-o", TAPWATCH, U.dir .. "tapwatch.c", "-framework", "CoreFoundation" })
  M._build = t
  t:start()
end

local function stopWatcher()
  watcherGen = watcherGen + 1
  if watcher then watcher:terminate() end
  watcher = nil
end

local function applyGesture()
  restarts = 0
  if config.values.threeFingerTap then startWatcher() else stopWatcher() end
end

-- 睡眠唤醒后触控板设备会重建，重启一下检测进程
local wakeWatcher = hs.caffeinate.watcher.new(function(event)
  if event == hs.caffeinate.watcher.systemDidWake and config.values.threeFingerTap then
    stopWatcher()
    U.after(1, startWatcher)
  end
end)

---------------------------------------------------------------------------
-- 快捷键
---------------------------------------------------------------------------

local hotkey

local function bindHotkey()
  if hotkey then hotkey:delete() end
  hotkey = nil
  local h = config.values.hotkey
  local ok, res = pcall(hs.hotkey.bind, h.mods, h.key, function() M.lookup("hotkey") end)
  if ok and res then hotkey = res end
  return hotkey ~= nil
end

local function changeHotkey(mods, key)
  local old = config.values.hotkey
  config.set("hotkey", { mods = mods, key = key })
  if bindHotkey() then return true end
  config.set("hotkey", old)
  bindHotkey()
  return false, "这个按键组合用不了"
end

---------------------------------------------------------------------------
-- 菜单栏
---------------------------------------------------------------------------

local menubar

local function setupMenubar()
  menubar = hs.menubar.new(true, "llmLookup")
  local icon = hs.image.imageFromPath(U.dir .. "menubar.png")
  if icon then
    menubar:setIcon(icon:setSize({ w = 18, h = 18 }), true)
  else
    menubar:setTitle("译")
  end
  menubar:setTooltip("划词查词")
  menubar:setMenu(function()
    local v = config.values
    local items = { { title = "模型配置", disabled = true } }
    for _, p in ipairs(v.profiles) do
      items[#items + 1] = {
        title = "    " .. p.name, checked = p.id == v.active,
        fn = function()
          config.setActive(p.id)
          settings.refresh()
        end,
      }
    end
    for _, item in ipairs({
      { title = "-" },
      { title = "三指轻点查词", checked = v.threeFingerTap, fn = function()
        config.set("threeFingerTap", not v.threeFingerTap)
        applyGesture()
        settings.refresh()
      end },
      { title = "设置…", fn = settings.open },
      { title = "-" },
      -- Hammerspoon 自己的菜单栏图标隐藏了，常用的两项放到这里
      { title = "重新载入", fn = hs.reload },
      { title = "调试控制台", fn = function() hs.openConsole(true) end },
    }) do
      items[#items + 1] = item
    end
    return items
  end)
end

---------------------------------------------------------------------------
-- 打开 App 就是设置面板
---------------------------------------------------------------------------

-- 当前登录会话已经多少秒（看 loginwindow 进程的 etime，格式 [[天-]时:]分:秒）
local function sinceLogin()
  local out = hs.execute([[ps -o etime= -p "$(pgrep -xu "$USER" loginwindow | head -1)" 2>/dev/null]]) or ""
  local days, rest = out:match("(%d+)%-([%d:]+)")
  local secs = 0
  for n in (rest or out):gmatch("%d+") do secs = secs * 60 + tonumber(n) end
  return secs + (tonumber(days) or 0) * 86400
end

-- 用户自己打开的 App 才弹面板：重新载入配置（同一个进程）、登录自启、带 LLM_LOOKUP_QUIET 启动的都不算
local function openedByUser()
  local pid = hs.processInfo.processID
  if hs.settings.get("llmLookup.pid") == pid then return false end
  hs.settings.set("llmLookup.pid", pid)
  return os.getenv("LLM_LOOKUP_QUIET") == nil and sinceLogin() > 120
end

---------------------------------------------------------------------------

settings.hooks = {
  onChange = function(key)
    if key == "threeFingerTap" then
      applyGesture()
    elseif key == "width" or key == "maxHeight" then
      popup.rebuild()
    end
  end,
  onProfilesChanged = function() backends.prefetch() end,
  onHotkey = changeHotkey,
  onRecording = function(on)
    if hotkey then
      if on then hotkey:disable() else hotkey:enable() end
    end
  end,
}

M.openSettings = settings.open

-- 调试用：hs -c 'return hs.inspect(llmLookup._debug.pointQuery(hs.mouse.absolutePosition()))'
M._debug = { pointQuery = capture.pointQuery, selectedText = capture.selectedText }

function M.start()
  -- 辅助功能查询是同步的，超时压短，免得某个应用卡住时拖住 Hammerspoon
  hs.axuielement.systemWideElement():setTimeout(0.2)
  backends.prefetch()
  bindHotkey()
  applyGesture()
  wakeWatcher:start()
  -- 菜单栏只留一个图标：隐藏 Hammerspoon 自带的
  hs.menuIcon(false)
  setupMenubar()
  -- App 已经在运行时再打开它（访达、聚焦、启动台），系统发的是「重新打开」：弹设置面板，不弹控制台
  hs.openConsoleOnDockClick(false)
  hs.dockIconClickCallback = function() settings.open() end
  if openedByUser() then settings.open() end
  log.i("started, " .. backends.describe(config.active()))
  return M
end

return M
