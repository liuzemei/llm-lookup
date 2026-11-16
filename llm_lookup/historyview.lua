-- 历史记录窗口：左边列表、右边对话内容，可以搜索、复制、删除，或者在浮窗里接着问

local history = require("llm_lookup.history")
local U = require("llm_lookup.util")

local V = {}

V.onResume = nil -- 由 init 设置：onResume(id) 在浮窗里接着这段对话问

local wv, uc, ready, queue = nil, nil, false, {}

local function js(fn, arg)
  if not wv then return end
  local call = fn .. "(" .. hs.json.encode({ arg }) .. "[0])"
  if ready then wv:evaluateJavaScript(call) else queue[#queue + 1] = call end
end

local handlers = {}

function handlers.ready()
  ready = true
  for _, call in ipairs(queue) do wv:evaluateJavaScript(call) end
  queue = {}
  js("load", history.list())
end

function handlers.resume(m) if V.onResume then V.onResume(m.id) end end
function handlers.remove(m) history.remove(m.id) end
function handlers.clear() history.clear() end
function handlers.close() V.close() end

-- Hammerspoon 没有「编辑」菜单，页面里的复制粘贴走这里
function handlers.copy(m) if type(m.text) == "string" then hs.pasteboard.setContents(m.text) end end
function handlers.paste() js("pasteText", hs.pasteboard.getContents() or "") end

function handlers.open(m)
  if type(m.url) == "string" and m.url:match("^https?://") then hs.urlevent.openURL(m.url) end
end

function V.open()
  if wv then
    wv:show()
    hs.focus()
    local win = wv:hswindow()
    if win then win:focus() end
    return
  end
  ready, queue = false, {}
  uc = hs.webview.usercontent.new("history")
  uc:setCallback(function(msg)
    local m = msg.body or {}
    local h = handlers[m.type]
    if h then h(m) end
  end)
  local sf = hs.screen.mainScreen():frame()
  local w, h = math.min(900, sf.w - 80), math.min(640, sf.h - 80)
  local html = U.readFile("history.html"):gsub("/%*__MD__%*/", function() return U.readFile("md.js") end)
  -- 标题栏默认是浅色半透明的，和页面对不上。铺满内容区后标题栏底下是页面的底色
  -- （网页会自己让出标题栏的高度）；深浅色跟着系统
  wv = hs.webview.new({ x = sf.x + (sf.w - w) / 2, y = sf.y + (sf.h - h) / 2, w = w, h = h }, {}, uc)
      :windowStyle({ "titled", "closable", "miniaturizable", "resizable", "fullSizeContentView" })
      :darkMode(hs.host.interfaceStyle() == "Dark")
      :windowTitle("历史记录")
      :allowTextEntry(true)
      :deleteOnClose(true)
      :windowCallback(function(action)
        if action == "closing" then wv, ready = nil, false end
      end)
      :html(html)
  wv:show()
  -- 激活 Hammerspoon，搜索框才能接收键盘
  hs.focus()
  local win = wv:hswindow()
  if win then win:focus() end
end

function V.close()
  if wv then wv:delete() end
  wv, ready = nil, false
end

-- 记录有变化时同步到打开着的窗口
function V.refresh()
  if wv and ready then js("load", history.list()) end
end

-- 调试用：在窗口里执行一段 JS，结果交给 cb
function V._eval(code, cb) if wv then wv:evaluateJavaScript(code, cb or function() end) end end

return V
