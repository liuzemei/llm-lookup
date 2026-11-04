-- 取文字：选中的文字、鼠标下的词（带上下文），必要时模拟 ⌘C / 双击

local config = require("llm_lookup.config")
local U = require("llm_lookup.util")

local ax = hs.axuielement
local types = hs.eventtap.event.types
local props = hs.eventtap.event.properties
local log = hs.logger.new("llmLookup", "info")

local CONTEXT_CHARS = 160
local MAX_INPUT_CHARS = 6000
local MAX_TERM_CHARS = 300

local GHOSTTY = "com.mitchellh.ghostty"
-- VS Code 系编辑器：打开辅助功能树会让它切到「屏幕阅读器优化」模式，所以不开；没选中时按 ⌘C 会复制整行
local VSCODE_APPS = {
  ["com.microsoft.VSCode"] = true, ["com.microsoft.VSCodeInsiders"] = true,
  ["com.todesktop.230313mzl4w4u92"] = true, -- Cursor
  ["com.exafunction.windsurf"] = true, ["com.vscodium"] = true,
}

local K = {}

local function isCJK(c)
  return (c >= 0x3040 and c <= 0x30FF) or (c >= 0x3400 and c <= 0x9FFF)
      or (c >= 0xF900 and c <= 0xFAFF) or (c >= 0xAC00 and c <= 0xD7AF)
end

local function round(x) return math.floor(x + 0.5) end

local function bundleOf(el)
  local pid = el and el:pid()
  local app = pid and hs.application.applicationForPID(pid)
  return app and app:bundleID(), app
end

function K.selectedText()
  local el = ax.systemWideElement():attributeValue("AXFocusedUIElement")
  local t = el and el:attributeValue("AXSelectedText")
  if type(t) == "string" and t:find("%S") then return t end
end

-- 焦点控件里有字、并且明确报告选区长度为 0，就不用再按 ⌘C 去试（Electron 的空分组也会报 0，不能信）
local function noSelection()
  local el = ax.systemWideElement():attributeValue("AXFocusedUIElement")
  local r = el and el:attributeValue("AXSelectedTextRange")
  local n = el and el:attributeValue("AXNumberOfCharacters")
  return type(r) == "table" and r.length == 0 and type(n) == "number" and n > 0
end

local axEnabledPids = {}
local function enableChromiumAX(el)
  local pid = el and el:pid()
  if not pid or axEnabledPids[pid] then return end
  axEnabledPids[pid] = true
  if VSCODE_APPS[bundleOf(el)] then return end
  local appEl = ax.applicationElementForPID(pid)
  if appEl then pcall(appEl.setAttributeValue, appEl, "AXManualAccessibility", true) end
end

local function ancestorWithRole(el, role)
  for _ = 1, 40 do
    if not el then return end
    if el:attributeValue("AXRole") == role then return el end
    el = el:attributeValue("AXParent")
  end
end

---------------------------------------------------------------------------
-- Ghostty：终端区域只给整个缓冲区的文字（回滚历史 + 当前屏幕，软折行合并成一行），不给坐标。
-- 按它的字符网格自己算鼠标指着第几行第几列；格子大小和 Ghostty 一样由字体按物理像素取整得出
---------------------------------------------------------------------------

local grids = {} -- 缩放倍数 → { at, grid }

-- 终端里的字宽：中日韩、全角、emoji 占两格，组合符号不占格
local function cellWidth(c)
  if c < 0x1100 then return (c >= 0x300 and c <= 0x36F) and 0 or 1 end
  if (c >= 0x200B and c <= 0x200F) or (c >= 0xFE00 and c <= 0xFE0F) then return 0 end
  if c <= 0x115F or (c >= 0x2E80 and c <= 0xA4CF and c ~= 0x303F) or (c >= 0xAC00 and c <= 0xD7A3)
      or (c >= 0xF900 and c <= 0xFAFF) or (c >= 0xFE30 and c <= 0xFE4F) or (c >= 0xFF00 and c <= 0xFF60)
      or (c >= 0xFFE0 and c <= 0xFFE6) or (c >= 0x1F300 and c <= 0x1FAFF) or (c >= 0x20000 and c <= 0x3FFFD) then
    return 2
  end
  return 1
end

-- 读 Ghostty 生效的配置（字体、字号、格子微调、边距），一分钟内复用
local function ghosttyGrid(app, scale)
  local cached = grids[scale]
  if cached and hs.timer.secondsSinceEpoch() - cached.at < 60 then return cached.grid end
  local out = hs.execute(U.shellQuote(app:path() .. "/Contents/MacOS/ghostty") .. " +show-config 2>/dev/null") or ""
  local cfg = {}
  for k, v in out:gmatch("([%w%-]+) = ([^\n]*)") do
    if (cfg[k] or "") == "" then cfg[k] = v end
  end

  local size = tonumber(cfg["font-size"]) or 13
  local name
  if (cfg["font-family"] or "") ~= "" then
    local fonts = hs.styledtext.fontsForFamily(cfg["font-family"]) or {}
    for _, f in ipairs(fonts) do
      if f[2] == "Regular" then name = f[1] end
    end
    name = name or (fonts[1] and fonts[1][1])
  end
  local advance, height
  if name then
    local info = hs.styledtext.fontInfo({ name = name, size = size })
    advance = hs.drawing.getTextDrawingSize(string.rep("0", 100), { font = name, size = size }).w / 100
    height = info.ascender - info.descender + info.leading
  else
    -- 没配字体时 Ghostty 用自带的 JetBrains Mono，系统里量不到，按它的字形比例估
    advance, height = size * 0.6, size * 1.32
  end

  -- adjust-cell-*：整数是加减的像素，百分比按比例
  local function adjust(px, v)
    local pct = (v or ""):match("^(-?[%d.]+)%%$")
    if pct then return round(px * (1 + tonumber(pct) / 100)) end
    return px + (tonumber(v or "") or 0)
  end
  -- window-padding-*：「10」或「左,右」
  local function pad(v)
    local a, b = (v or ""):match("^%s*([%d.]+)%s*,?%s*([%d.]*)")
    a = tonumber(a) or 2
    return a, tonumber(b) or a
  end
  local grid = {
    w = adjust(round(advance * scale), cfg["adjust-cell-width"]) / scale,
    h = adjust(round(height * scale), cfg["adjust-cell-height"]) / scale,
    balance = cfg["window-padding-balance"] == "true",
  }
  grid.left, grid.right = pad(cfg["window-padding-x"])
  grid.top, grid.bottom = pad(cfg["window-padding-y"])
  grids[scale] = { at = hs.timer.secondsSinceEpoch(), grid = grid }
  return grid
end

-- 一行文字按 cols 列折行：返回占几行；给了目标格子 (tr, tc) 时，再返回落在那一格上的字的字节位置
local function wrapLine(line, cols, tr, tc)
  if not line:find("[\128-\255]") then
    local i = tr and (tr * cols + tc + 1)
    return math.max(1, math.ceil(#line / cols)), (i and i <= #line) and i or nil
  end
  local r, c, hit = 0, 0, nil
  for p, cp in utf8.codes(line) do
    local w = cellWidth(cp)
    if c + w > cols then r, c = r + 1, 0 end -- 宽字符放不下就整个挪到下一行
    if tr and not hit and r == tr and tc >= c and tc < c + math.max(w, 1) then hit = p end
    c = c + w
  end
  return r + 1, hit
end

local function ghosttyTextAround(el, pos, app)
  if el:attributeValue("AXRole") ~= "AXTextArea" then return end
  local f = el:attributeValue("AXFrame")
  local text = el:attributeValue("AXValue")
  if not f or type(text) ~= "string" then return end
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local g = ghosttyGrid(app, screen:currentMode().scale)

  local W, H = f.w - g.left - g.right, f.h - g.top - g.bottom
  local cols, rows = math.floor(W / g.w + 1e-6), math.floor(H / g.h + 1e-6)
  if cols < 1 or rows < 1 then return end
  local x0, y0 = f.x + g.left, f.y + g.top
  if g.balance then x0, y0 = x0 + (W - cols * g.w) / 2, y0 + (H - rows * g.h) / 2 end
  local col, row = math.floor((pos.x - x0) / g.w), math.floor((pos.y - y0) / g.h)
  if col < 0 or col >= cols or row < 0 or row >= rows then return "", "" end

  local lines, counts, total = {}, {}, 0
  for l in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = l
    counts[#lines] = wrapLine(l, cols)
    total = total + counts[#lines]
  end
  -- 当前可见的是哪一段：滚动条 0 = 最顶部；读不到就当在最底部
  local top = 0
  if total > rows then
    local area = el:attributeValue("AXParent")
    local bar = area and area:attributeValue("AXVerticalScrollBar")
    local v = bar and tonumber(bar:attributeValue("AXValue"))
    top = v and round(v * (total - rows)) or (total - rows)
  end

  local target = top + row
  for i, l in ipairs(lines) do
    if target < counts[i] then
      local _, p = wrapLine(l, cols, target, col)
      if not p then return "", "" end -- 指着空白处
      return l:sub(1, p - 1), l:sub(p)
    end
    target = target - counts[i]
  end
  return "", ""
end

---------------------------------------------------------------------------

-- 读鼠标所在位置前后的文字：原生文本控件走 AXRangeForPosition，网页走 TextMarker，Ghostty 自己算
-- （Chrome 声明支持 AXTextMarkerForPosition，但实际总返回空，所以 Chrome 网页里读不到）
-- 第三个返回值为 true 表示结果可信：读到的是空白就真的是空白（目前只有 Ghostty）
local function textAroundPoint(el, pos)
  local bundle, app = bundleOf(el)
  if bundle == GHOSTTY then
    local before, after = ghosttyTextAround(el, pos, app)
    return before, after, true
  end

  local r = el:parameterizedAttributeValue("AXRangeForPosition", pos)
  local total = el:attributeValue("AXNumberOfCharacters")
  -- Cursor 等 Electron 应用的空分组也会回答位置 0，里面没有字就当读不到
  if type(r) == "table" and r.location and total ~= 0 then
    total = total or (r.location + CONTEXT_CHARS)
    -- 多读一些，网址、路径这种长串要整段取
    local s = math.max(0, r.location - CONTEXT_CHARS - MAX_TERM_CHARS)
    local e = math.min(total, r.location + CONTEXT_CHARS + MAX_TERM_CHARS)
    return el:parameterizedAttributeValue("AXStringForRange", { location = s, length = r.location - s }),
        el:parameterizedAttributeValue("AXStringForRange", { location = r.location, length = e - r.location })
  end

  local area = ancestorWithRole(el, "AXWebArea")
  local m = area and area:parameterizedAttributeValue("AXTextMarkerForPosition", pos)
  if not m then return end
  local para = area:parameterizedAttributeValue("AXParagraphTextMarkerRangeForTextMarker", m)
      or area:parameterizedAttributeValue("AXLineTextMarkerRangeForTextMarker", m)
  if not para then return end
  local tm = ax.axtextmarker
  return area:parameterizedAttributeValue("AXStringForTextMarkerRange", tm.newRange(para:startMarker(), m)),
      area:parameterizedAttributeValue("AXStringForTextMarkerRange", tm.newRange(m, para:endMarker()))
end

local function context(before, mid, after)
  return U.trim(U.utf8Tail(before, CONTEXT_CHARS) .. "⟦" .. mid .. "⟧" .. U.utf8Head(after, CONTEXT_CHARS))
end

-- 网址、路径、邮箱、a.b、a::b 这类整段取
local function looksLikeTerm(t)
  return t:find("://", 1, true) or t:find("[/\\]") or t:find("::", 1, true) or t:find("%w@%w") or t:find("%w%.%a")
end

-- 剥掉外面包着的标点：(https://x.com) 的括号、句末的句号；括号成对时保留，比如 wiki/Foo_(bar)
local CLOSE_OF = { [")"] = "(", ["]"] = "[", ["}"] = "{", [">"] = "<" }
local function count(s, ch) return select(2, s:gsub("%" .. ch, "")) end
local function trimPunct(t)
  local s, e = 1, #t
  while s <= e and t:sub(s, s):find("[%(%[{<\"'`]") do s = s + 1 end
  while e >= s do
    local ch = t:sub(e, e)
    local open = CLOSE_OF[ch]
    if ch:find("[%.,;:!?\"'`]") or (open and count(t:sub(s, e), open) < count(t:sub(s, e), ch)) then
      e = e - 1
    else
      break
    end
  end
  return s, e
end

local function termAt(before, after)
  local head = after:match("^[%w%p]*")
  if head == "" then return end
  local tail = before:match("[%w%p]*$")
  local tok = tail .. head
  if #tok > MAX_TERM_CHARS or not looksLikeTerm(tok) then return end
  local s, e = trimPunct(tok)
  -- 函数调用只取到括号前：os.path.join(a, b) → os.path.join
  local paren = tok:find("(", s, true)
  if paren and paren <= e and count(tok:sub(s, e), "(") > count(tok:sub(s, e), ")") then e = paren - 1 end
  if #tail + 1 < s or #tail + 1 > e then return end -- 指着的是外面的标点
  local term = tok:sub(s, e)
  if not looksLikeTerm(term) then return end
  return {
    kind = "word", word = term,
    context = context(before:sub(1, #before - #tail) .. tok:sub(1, s - 1), term, tok:sub(e + 1) .. after:sub(#head + 1)),
  }
end

local function wordAt(before, after)
  local head = after:match("^[%w_'%-]+") or ""
  local tail = before:match("[%w_'%-]*$") or ""
  local word = (tail .. head):gsub("^['%-]+", ""):gsub("['%-]+$", "")
  if word == "" then return end
  return {
    kind = "word", word = word,
    context = context(before:sub(1, #before - #tail), tail .. head, after:sub(#head + 1)),
  }
end

-- 第二个返回值为 true 表示确定鼠标下面没有词（不用再模拟点击去试）
function K.pointQuery(pos)
  local el = ax.systemElementAtPosition(pos)
  if not el then return end
  if config.values.enableChromiumAX then enableChromiumAX(el) end
  local before, after, trusted = textAroundPoint(el, pos)
  if type(before) ~= "string" or type(after) ~= "string" then return end
  -- 上下文只留当前这一段
  before = before:match("[^\r\n]*$")
  after = after:match("^[^\r\n]*")

  local c = after ~= "" and utf8.codepoint(after, 1)
  if c and isCJK(c) then
    local ch = utf8.char(c)
    return { kind = "cjk", char = ch, context = context(before, ch, after:sub(#ch + 1)) }
  end
  local q = termAt(before, after) or wordAt(before, after)
  if q then return q end
  return nil, trusted
end

-- VS Code 系编辑器没选中时 ⌘C 复制的是整行：剪贴板里会带 isFromEmptySelection 标记（UTF-16 编码）
local EMPTY_SELECTION = (('"isFromEmptySelection":true'):gsub(".", "%0\0"))
local function copiedWholeLine(bundle, text)
  local data = hs.pasteboard.readDataForUTI("org.chromium.web-custom-data")
  if data and data:find(EMPTY_SELECTION, 1, true) then return true end
  return VSCODE_APPS[bundle] and type(text) == "string" and text:match("^[^\n]*\n$") ~= nil
end

-- 模拟 ⌘C 拿选中文字，拿完把剪贴板恢复原样
local function copySelection(cb)
  local pb = hs.pasteboard
  local before = pb.changeCount()
  local saved = pb.readAllData()
  local front = hs.application.frontmostApplication()
  local bundle = front and front:bundleID()
  hs.eventtap.keyStroke({ "cmd" }, "c", 0)
  local tries = 0
  local function poll()
    tries = tries + 1
    if pb.changeCount() ~= before then
      local t = pb.getContents()
      local wholeLine = copiedWholeLine(bundle, t)
      if saved and next(saved) then pb.writeAllData(saved) else pb.clearContents() end
      cb(not wholeLine and t or nil)
    elseif tries < 8 then
      U.after(0.04, poll)
    else
      cb(nil)
    end
  end
  U.after(0.04, poll)
end

-- 双击会触发这些控件的默认行为（打开链接、打开文件……），碰到就不双击
local NO_DOUBLE_CLICK_ROLES = {
  AXLink = true, AXButton = true, AXImage = true, AXCheckBox = true, AXRadioButton = true,
  AXPopUpButton = true, AXMenuButton = true, AXMenuItem = true, AXMenuBarItem = true,
  AXDisclosureTriangle = true, AXDockItem = true,
}
local NO_DOUBLE_CLICK_APPS = {
  ["com.apple.finder"] = true,
  ["com.apple.iWork.Numbers"] = true,
  ["com.microsoft.Excel"] = true,
}

local function canDoubleClick(pos)
  local el = ax.systemElementAtPosition(pos)
  if not el then return false end
  if NO_DOUBLE_CLICK_APPS[bundleOf(el)] then return false end
  for i = 1, 4 do
    if not el then break end
    local role = el:attributeValue("AXRole")
    -- 读不到角色（比如应用卡住、辅助功能超时）就不冒险双击
    if (i == 1 and not role) or NO_DOUBLE_CLICK_ROLES[role] then return false end
    el = el:attributeValue("AXParent")
  end
  return true
end

local function doubleClickCopy(pos, cb)
  for i = 1, 2 do
    hs.eventtap.event.newMouseEvent(types.leftMouseDown, pos):setFlags({})
        :setProperty(props.mouseEventClickState, i):post()
    hs.eventtap.event.newMouseEvent(types.leftMouseUp, pos):setFlags({})
        :setProperty(props.mouseEventClickState, i):post()
  end
  U.after(0.08, function() copySelection(cb) end)
end

-- 顺序：选中文字(AX) → 鼠标下的文字(AX) → ⌘C → 双击选词再 ⌘C
-- cb(q, why)：q.via 记下是哪一步拿到的，why 是没拿到的原因，都只用于日志
function K.acquire(selSnapshot, pos, cb)
  local ok, sel = pcall(K.selectedText)
  sel = selSnapshot or (ok and sel)
  if sel then return cb({ kind = "selection", text = sel, via = selSnapshot and "snapshot" or "selection" }) end

  local okP, q, blank = pcall(K.pointQuery, pos)
  if not okP then log.w("pointQuery: " .. tostring(q)) end
  if okP and q then
    q.via = "point"
    return cb(q)
  end
  if okP and blank then return cb(nil, "blank") end

  local function doubleClick()
    local okD, can = pcall(canDoubleClick, pos)
    if not (config.values.doubleClickFallback and okD and can) then return cb(nil, "no-double-click") end
    doubleClickCopy(pos, function(w)
      if w and w:find("%S") then return cb({ kind = "selection", text = w, via = "double-click" }) end
      cb(nil, "double-click")
    end)
  end
  local okN, none = pcall(noSelection)
  if okN and none then return doubleClick() end
  copySelection(function(t)
    if t and t:find("%S") then return cb({ kind = "selection", text = t, via = "copy" }) end
    doubleClick()
  end)
end

-- 返回 发给模型的内容, 浮窗标题
function K.buildPrompt(q)
  if q.kind == "selection" then
    local text = U.utf8Head(U.trim(q.text), MAX_INPUT_CHARS)
    return ('请解析下面这段文字：\n"""\n%s\n"""'):format(text), (text:gsub("%s+", " "))
  elseif q.kind == "word" then
    return ("上下文：%s\n要查的词：%s"):format(q.context, q.word), q.word
  else
    return ("上下文：%s\n我指向的是 ⟦⟧ 标出的字，请判断它所在的词语，按单词的格式解释这个词。")
        :format(q.context), q.char .. " …"
  end
end

return K
