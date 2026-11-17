-- 结果浮窗：鼠标旁边的无边框卡片，内容边生成边显示

local config = require("llm_lookup.config")
local U = require("llm_lookup.util")

local P = {}

local PAD = 20 -- 窗口四周留给阴影的透明边
local types = hs.eventtap.event.types
local log = hs.logger.new("llmLookup", "info")

P.onClose = nil -- 由 init 设置：关掉浮窗时顺便取消正在跑的请求
P.onAsk = nil   -- 由 init 设置：在浮窗底部输入了追问
P.text = ""

local wv, uc, ready, queue, anchor
local closeGen = 0
local sticky -- 问答框：点外面不关，只能 Esc / 关闭按钮 / 快捷键关
local dragTap, dragFrom -- 拖动标题栏移动窗口
local prevWin, typed -- 查词前的焦点窗口；用户点过输入框的话，按 Esc 关掉时把焦点还回去

local escKey -- 浮窗显示时按 Esc 关掉；在下面创建，这里先声明给 ensure 里的回调用

local function js(fn, arg)
  if not wv then return end
  local call = fn .. "(" .. hs.json.encode({ arg }) .. "[0])"
  if ready then wv:evaluateJavaScript(call) else queue[#queue + 1] = call end
end

local function setHeight(h)
  if not (wv and anchor) then return end
  local v = config.values
  h = math.min(h, v.maxHeight + 2 * PAD)
  wv:frame({ x = anchor.x, y = anchor.up and (anchor.y - h) or anchor.y, w = v.width + 2 * PAD, h = h })
end

local function ensure()
  if wv then return end
  ready, queue = false, {}
  uc = hs.webview.usercontent.new("lookup")
  uc:setCallback(function(msg)
    local b = msg.body or {}
    if b.type == "ready" then
      ready = true
      for _, call in ipairs(queue) do wv:evaluateJavaScript(call) end
      queue = {}
    elseif b.type == "height" then
      setHeight(b.h)
    elseif b.type == "copy" then
      hs.pasteboard.setContents(P.text or "")
    elseif b.type == "close" then
      P.close(b.refocus)
    elseif b.type == "focus" then
      typed = true
    elseif b.type == "setClipboard" then
      if type(b.text) == "string" then hs.pasteboard.setContents(b.text) end
    elseif b.type == "paste" then
      local t = hs.pasteboard.getContents()
      if t then js("pasteText", t) end
    elseif b.type == "composing" then
      if b.on then escKey:disable() elseif wv and wv:isVisible() then escKey:enable() end
    elseif b.type == "ask" then
      if P.onAsk and type(b.q) == "string" then P.onAsk(b.q) end
    elseif b.type == "dragStart" then
      P.startDrag()
    elseif b.type == "open" then
      if type(b.url) == "string" and b.url:match("^https?://") then hs.urlevent.openURL(b.url) end
    end
  end)
  local v = config.values
  local html = U.readFile("popup.html"):gsub("__PAD__", tostring(PAD)):gsub("__MAXCARD__", tostring(v.maxHeight))
      :gsub("/%*__MD__%*/", function() return U.readFile("md.js") end)
  wv = hs.webview.new({ x = 0, y = 0, w = v.width + 2 * PAD, h = 100 }, {}, uc)
      :windowStyle({ "borderless", "nonactivating" })
      :transparent(true)
      :shadow(false)
      :allowTextEntry(true)
      :level(hs.drawing.windowLevels.popUpMenu)
      :behaviorAsLabels({ "canJoinAllSpaces", "fullScreenAuxiliary" })
      :html(html)
end

-- 宽度、高度改了之后下次重新建
function P.rebuild()
  P.close()
  if wv then wv:delete() end
  wv = nil
end


escKey = hs.hotkey.new({}, "escape", function() P.close(true) end)

-- 按卡片本身判断，点到阴影那圈透明边也算点在外面
local clickWatcher = hs.eventtap.new({ types.leftMouseDown, types.rightMouseDown }, function(e)
  if wv and wv:isVisible() then
    local p, f = e:location(), wv:frame()
    if p.x < f.x + PAD or p.x > f.x + f.w - PAD or p.y < f.y + PAD or p.y > f.y + f.h - PAD then
      U.after(0, P.close)
    end
  end
  return false
end)

-- 标题栏按下后跟着鼠标走，松开为止；在 Lua 这边按屏幕坐标算，窗口移动不影响
function P.startDrag()
  if not (wv and anchor) then return end
  if dragTap then dragTap:stop() end
  dragFrom = hs.mouse.absolutePosition()
  dragTap = hs.eventtap.new({ types.leftMouseDragged, types.leftMouseUp }, function(e)
    if e:getType() == types.leftMouseUp then
      dragTap:stop()
      return false
    end
    local p = hs.mouse.absolutePosition()
    anchor.x, anchor.y = anchor.x + p.x - dragFrom.x, anchor.y + p.y - dragFrom.y
    dragFrom = p
    local f = wv:frame()
    setHeight(f.h)
    return false
  end):start()
end

function P.isSticky() return sticky and wv ~= nil and wv:isVisible() end

-- opts.ask：问答框，打开就是空白的输入框；opts.turns：从历史记录恢复的对话 { {u = 问题或 nil, a = 回答}, ... }
function P.show(pos, title, label, opts)
  opts = opts or {}
  local v = config.values
  local sf = hs.mouse.getCurrentScreen():frame()
  local w = v.width + 2 * PAD
  -- 卡片放在鼠标下方 12pt；下面放不下且上面更宽敞时放到上方
  local below = pos.y + 12
  local up = below + v.maxHeight > sf.y + sf.h and pos.y - sf.y > sf.y + sf.h - below
  anchor = {
    x = math.max(sf.x - PAD, math.min(pos.x - 28 - PAD, sf.x + sf.w - w + PAD)),
    y = up and (pos.y - 8 + PAD) or (below - PAD),
    up = up,
  }
  closeGen = closeGen + 1 -- 又要显示了，取消关闭后的核对
  ensure()
  P.text = ""
  prevWin, typed = hs.window.focusedWindow(), false
  js("reset", { q = title, label = label, ask = opts.ask, turns = opts.turns })
  setHeight(110)
  wv:show()
  -- 浮窗不激活 Hammerspoon 也能成为键盘焦点，直接把光标放进输入框
  if opts.ask or opts.turns then js("focusAsk") end
  escKey:enable()
  sticky = opts.ask == true
  if sticky then clickWatcher:stop() else clickWatcher:start() end
end

function P.render(text)
  P.text = text
  js("render", text)
end

function P.note(text) js("note", text) end
function P.fail(msg) js("fail", msg) end
function P.finish(ok) js("finish", ok == true) end
function P.ask(q)
  P.text = ""
  js("followUp", q)
end

-- 偶尔窗口已经隐藏了，窗口服务器却还把它画在屏幕上，留下一张点不动、关不掉的卡片。
-- 关掉后核对一下，还在屏幕上就整个销毁，下次查词再新建
local function onScreen()
  local f = wv:frame()
  for _, w in ipairs(hs.window.list(true) or {}) do
    local b = w.kCGWindowBounds
    if w.kCGWindowOwnerPID == hs.processInfo.processID and w.kCGWindowIsOnscreen and b
        and math.abs(b.X - f.x) < 2 and math.abs(b.Y - f.y) < 2
        and math.abs(b.Width - f.w) < 2 and math.abs(b.Height - f.h) < 2 then
      return true
    end
  end
end

local function ensureGone(gen)
  if gen ~= closeGen or not wv or wv:isVisible() then return end
  if onScreen() then
    log.w("浮窗隐藏后仍留在屏幕上，销毁重建")
    wv:delete()
    wv = nil
  end
end

-- refocus：Esc / 关闭按钮关掉时为 true；点到外面关掉时焦点本来就去了别处，不用管
function P.close(refocus)
  if P.onClose then P.onClose() end
  escKey:disable()
  clickWatcher:stop()
  if dragTap then dragTap:stop() end
  sticky = false
  if not wv then return end
  local wasVisible = wv:isVisible()
  wv:hide()
  if refocus and wasVisible and typed and prevWin and prevWin:isVisible() then prevWin:focus() end
  closeGen = closeGen + 1
  if wasVisible then
    local gen = closeGen
    U.after(0.5, function() ensureGone(gen) end)
    U.after(2, function() ensureGone(gen) end)
  end
end

-- 调试用：在浮窗里执行一段 JS，结果交给 cb
function P._eval(code, cb) if wv then wv:evaluateJavaScript(code, cb or function() end) end end

return P
