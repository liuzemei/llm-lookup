-- 结果浮窗：鼠标旁边的无边框卡片，内容边生成边显示

local config = require("llm_lookup.config")
local U = require("llm_lookup.util")

local P = {}

local PAD = 20 -- 窗口四周留给阴影的透明边
local types = hs.eventtap.event.types

P.onClose = nil -- 由 init 设置：关掉浮窗时顺便取消正在跑的请求
P.text = ""

local wv, uc, ready, queue, anchor

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
      P.close()
    end
  end)
  local v = config.values
  local html = U.readFile("popup.html"):gsub("__PAD__", tostring(PAD)):gsub("__MAXBODY__", tostring(v.maxHeight - 40))
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

local escKey = hs.hotkey.new({}, "escape", function() P.close() end)

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

function P.show(pos, title, label)
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
  ensure()
  P.text = ""
  js("reset", { q = title, label = label })
  setHeight(110)
  wv:show()
  escKey:enable()
  clickWatcher:start()
end

function P.render(text)
  P.text = text
  js("render", text)
end

function P.fail(msg) js("fail", msg) end
function P.finish() js("finish") end

function P.close()
  if P.onClose then P.onClose() end
  if wv then wv:hide() end
  escKey:disable()
  clickWatcher:stop()
end

return P
