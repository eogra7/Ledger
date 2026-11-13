-- Ledger UI v0.4: portfolio dashboard window (Portfolio, Below vendor and Bank value tabs) + minimap button. Read-only.

local _, ns = ...
local floor = math.floor

local W, H = 860, 640
local PAD = 12
local CW = W - 2 * PAD            -- content width
local ROW_H = 16
local CAT_ROW_H = 14
local MAX_CATS = 10
local STALE_SECONDS = 12 * 3600

local C = {
  green  = {0.25, 0.85, 0.35},
  red    = {0.90, 0.30, 0.30},
  orange = {1.00, 0.60, 0.20},
  grey   = {0.60, 0.60, 0.60},
  gold   = {1.00, 0.82, 0.00},
  bar    = {0.30, 0.55, 0.90},
}
local function Hex(c) return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255) end
local GREEN, RED, ORANGE, GREY, GOLD = Hex(C.green), Hex(C.red), Hex(C.orange), Hex(C.grey), Hex(C.gold)

local frame
local tiles = {}
local catRows = {}
local rowPool = {}
local headerBtns = {}
local scroll, content
local lastData

------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------

local function M(c) return ns.Money(c) end

local function Pct(x, signed)
  if type(x) ~= "number" then return "-" end
  if signed then return string.format("%+.1f%%", x * 100) end
  return string.format("%.1f%%", x * 100)
end

local function GainColor(x)
  if type(x) ~= "number" then return "" end
  if x > 0 then return GREEN elseif x < 0 then return RED end
  return ""
end

local function Ago(t)
  local d = time() - t
  if d < 60 then return "just now" end
  if d < 3600 then return string.format("%dm ago", floor(d / 60)) end
  if d < 86400 then return string.format("%dh ago", floor(d / 3600)) end
  return string.format("%dd ago", floor(d / 86400))
end

local function FS(parent, template, justify, width)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
  if justify then fs:SetJustifyH(justify) end
  if width then fs:SetWidth(width) end
  if fs.SetWordWrap then fs:SetWordWrap(false) end
  return fs
end

local function Tex(parent, layer, c, a)
  local t = parent:CreateTexture(nil, layer or "ARTWORK")
  if t.SetColorTexture then
    t:SetColorTexture(c[1], c[2], c[3], a or 1)
  else
    t:SetTexture(c[1], c[2], c[3], a or 1)
  end
  return t
end

local function SetTexColor(t, c, a)
  if t.SetColorTexture then t:SetColorTexture(c[1], c[2], c[3], a or 1) else t:SetTexture(c[1], c[2], c[3], a or 1) end
end

------------------------------------------------------------------------
-- table columns and sorting
------------------------------------------------------------------------

local function lower(s) return type(s) == "string" and s:lower() or s end

local TAGW = 56
local COLS = {
  {key = "name",     label = "Item",        w = 130, j = "LEFT",   get = function(r) return lower(r.name) end, str = true},
  {key = "category", label = "Category",    w = 76,  j = "LEFT",   get = function(r) return lower(r.category) end, str = true},
  {key = "qty",      label = "Qty",         w = 70,  j = "RIGHT",  get = function(r) return r.qty end},
  {key = "price",    label = "Price ea",    w = 62,  j = "RIGHT",  get = function(r) return r.price end},
  {key = "cost",     label = "Cost basis",  w = 66,  j = "RIGHT",  get = function(r) return r.cost end},
  {key = "value",    label = "Market",      w = 66,  j = "RIGHT",  get = function(r) return r.value end},
  {key = "gain",     label = "Unrealized",  w = 66,  j = "RIGHT",  get = function(r) return r.gain end},
  {key = "pct",      label = "%",           w = 44,  j = "RIGHT",  get = function(r) return r.pct end},
  {key = "bar",      label = "Gain",        w = 80,  j = "CENTER", get = function(r) return r.pct end},
  {key = "trend",    label = "Trend",       w = 76,  j = "LEFT",   get = function(r) return r.trend end},
  {key = "tags",     label = "Flags",       w = TAGW, j = "LEFT",  get = function(r)
    return (r.sell and 2 or 0) + (r.cap and 1 or 0) end},
}
local COL_GAP = 2
do
  local x = 0
  for _, col in ipairs(COLS) do col.x = x; x = x + col.w + COL_GAP end
end
local COL_BY_KEY = {}
for _, col in ipairs(COLS) do COL_BY_KEY[col.key] = col end

local function SortRows(rows)
  local ui = ns.db.ui
  local col = COL_BY_KEY[ui.sortKey or "value"] or COL_BY_KEY.value
  local asc = ui.sortAsc and true or false
  local get = col.get
  table.sort(rows, function(a, b)
    local va, vb = get(a), get(b)
    if va == nil and vb == nil then return (a.name or "") < (b.name or "") end
    if va == nil then return false end   -- missing values always last
    if vb == nil then return true end
    if va == vb then return (a.name or "") < (b.name or "") end
    if asc then return va < vb end
    return va > vb
  end)
end

------------------------------------------------------------------------
-- building blocks
------------------------------------------------------------------------

local TILE_GAP = 6
local TILE_N = 7
local TILE_W = floor((CW - (TILE_N - 1) * TILE_GAP) / TILE_N)
local TILE_H = 44

local function MakeTile(i, label)
  local t = CreateFrame("Frame", nil, frame)
  t:SetSize(TILE_W, TILE_H)
  t:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + (i - 1) * (TILE_W + TILE_GAP), -56)
  local bg = Tex(t, "BACKGROUND", {1, 1, 1}, 0.06)
  bg:SetAllPoints()
  t.label = FS(t, "GameFontDisableSmall", "LEFT", TILE_W - 8)
  t.label:SetPoint("TOPLEFT", 4, -4)
  t.label:SetText(label)
  t.value = FS(t, "GameFontHighlight", "LEFT", TILE_W - 8)
  t.value:SetPoint("TOPLEFT", 4, -17)
  t.sub = FS(t, "GameFontHighlightSmall", "LEFT", TILE_W - 8)
  t.sub:SetPoint("TOPLEFT", 4, -31)
  return t
end

local CAT_NAME_W, CAT_BAR_W = 100, 380

local function MakeCatRow(i)
  local r = {}
  r.name = FS(frame, "GameFontHighlightSmall", "LEFT", CAT_NAME_W)
  r.bg = Tex(frame, "BACKGROUND", {1, 1, 1}, 0.07)
  r.bg:SetSize(CAT_BAR_W, CAT_ROW_H - 4)
  r.fill = Tex(frame, "ARTWORK", C.bar, 0.9)
  r.capLine = Tex(frame, "OVERLAY", C.orange, 0.8)
  r.capLine:SetSize(1, CAT_ROW_H - 2)
  r.label = FS(frame, "GameFontHighlightSmall", "LEFT", CW - CAT_NAME_W - CAT_BAR_W - 12)
  catRows[i] = r
  return r
end

local function PlaceCatRow(r, y)
  r.name:ClearAllPoints(); r.name:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
  r.bg:ClearAllPoints(); r.bg:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + CAT_NAME_W, y - 1)
  r.fill:ClearAllPoints(); r.fill:SetPoint("TOPLEFT", r.bg, "TOPLEFT", 0, 0)
  r.label:ClearAllPoints(); r.label:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + CAT_NAME_W + CAT_BAR_W + 8, y)
end

local function ShowCatRow(r, shown)
  for _, k in ipairs({"name", "bg", "fill", "capLine", "label"}) do
    if shown then r[k]:Show() else r[k]:Hide() end
  end
end

local function RowTooltip(row)
  local r = row.data
  if not r or not GameTooltip then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(r.name)
  GameTooltip:AddDoubleLine("Avg cost", M(r.avg), 1, 1, 1, 1, 1, 1)
  if r.price then
    local from = r.priceSrc == "ahdb" and ("AHDB scan " .. (r.scanT and date("%m-%d %H:%M", r.scanT) or ""))
      or (r.priceSrc == "auctionator" and "Auctionator") or "?"
    GameTooltip:AddDoubleLine("Lowest buyout", M(r.price), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("  from", from, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
    if r.median and r.median > 0 then
      GameTooltip:AddDoubleLine("Median buyout", M(r.median) .. (r.listed and ("  (" .. r.listed .. " listed)") or ""),
        1, 1, 1, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Sell after 5% cut", M(r.price * (1 - ns.AH_CUT)), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Sell-signal price", M(r.avg * (1 + ns.Setting("sell") / 100) / (1 - ns.AH_CUT)),
      1, 1, 1, 1, 1, 1)
  end
  local h = r.holdings
  if h then
    GameTooltip:AddLine(string.format("Bags %d  Bank %d  Mail %d  AH %d",
      h.bags or 0, h.bank or 0, h.mail or 0, h.auctions or 0), 0.8, 0.8, 0.8)
    if r.have and r.have ~= r.qty then
      GameTooltip:AddLine(string.format("Counted %d vs ledger qty %d (open bank/AH to refresh)", r.have, r.qty),
        C.orange[1], C.orange[2], C.orange[3])
      if r.missing then
        GameTooltip:AddLine("Used some crafting? Right-click > Mark as used.", C.orange[1], C.orange[2], C.orange[3])
      end
    end
  end
  if r.spark and #r.spark > 0 then
    GameTooltip:AddLine(" ")
    if r.sparkKind == "scan" then
      GameTooltip:AddDoubleLine("AHDB scan", "min / median (listed)", C.gold[1], C.gold[2], C.gold[3],
        C.gold[1], C.gold[2], C.gold[3])
    else
      GameTooltip:AddLine("Daily min price", C.gold[1], C.gold[2], C.gold[3])
    end
    for i = #r.spark, 1, -1 do
      local e = r.spark[i]
      local right = M(e.min)
      if r.sparkKind == "scan" then
        right = right .. " / " .. ((e.median or 0) > 0 and M(e.median) or "-") .. "  (" .. tostring(e.qty or 0) .. ")"
      end
      GameTooltip:AddDoubleLine(tostring(e.day), right, 0.8, 0.8, 0.8, 1, 1, 1)
    end
  end
  GameTooltip:Show()
end

-- Run a menu/dialog action; print any Lua error to chat instead of failing
-- silently (script errors are often turned off).
local function Safe(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then ns.Print("|cffff4040error:|r " .. tostring(err)) end
end

-- Ledger's own confirm/number box. Blizzard's StaticPopup shares the DIALOG
-- strata with the Ledger window and can open hidden behind it, so this one
-- sits above everything (FULLSCREEN_DIALOG) and is centred on the window.
local askFrame
local function Ask(text, default, onAccept)
  if not askFrame then
    local f = CreateFrame("Frame", "LedgerAskFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetSize(300, 130)
    if f.SetBackdrop then
      f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = {left = 3, right = 3, top = 3, bottom = 3},
      })
      f:SetBackdropColor(0.05, 0.05, 0.07, 0.97)
    else
      Tex(f, "BACKGROUND", {0.05, 0.05, 0.07}, 0.97):SetAllPoints()
    end
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.text:SetPoint("TOPLEFT", 12, -12)
    f.text:SetPoint("TOPRIGHT", -12, -12)
    f.text:SetJustifyH("LEFT")
    if f.text.SetWordWrap then f.text:SetWordWrap(true) end

    local eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    eb:SetSize(80, 20)
    eb:SetAutoFocus(false)
    eb:SetNumeric(true)
    eb:SetMaxLetters(6)
    f.edit = eb

    local function Btn(label, x)
      local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
      b:SetSize(90, 22)
      b:SetPoint("BOTTOM", f, "BOTTOM", x, 10)
      b:SetText(label)
      return b
    end
    f.ok = Btn(ACCEPT or "Accept", -50)
    f.cancel = Btn(CANCEL or "Cancel", 50)
    f.cancel:SetScript("OnClick", function() f:Hide() end)
    f.ok:SetScript("OnClick", function()
      local cb, n = f.onAccept, nil
      if f.edit:IsShown() then
        n = tonumber(f.edit:GetText() or "")
        if not (n and n > 0) then ns.Print("enter a number of items."); return end
        n = floor(n)
      end
      f:Hide()
      if cb then Safe(cb, n) end
    end)
    eb:SetScript("OnEnterPressed", function() f.ok:Click() end)
    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    f:SetScript("OnHide", function(self) self.edit:ClearFocus(); self.onAccept = nil end)
    if frame then frame:HookScript("OnHide", function() f:Hide() end) end
    if UISpecialFrames then table.insert(UISpecialFrames, "LedgerAskFrame") end
    askFrame = f
  end
  local f = askFrame
  f.text:SetText(text)
  f.onAccept = onAccept
  f:ClearAllPoints()
  f:SetPoint("CENTER", (frame and frame:IsShown()) and frame or UIParent, "CENTER")
  if default then
    f.edit:ClearAllPoints()
    f.edit:SetPoint("BOTTOM", f, "BOTTOM", 0, 42)
    f.edit:SetText(tostring(default))
    f.edit:Show()
    f:SetHeight(math.max(130, f.text:GetStringHeight() + 100))
  else
    f.edit:Hide()
    f:SetHeight(math.max(100, f.text:GetStringHeight() + 64))
  end
  f:Show()
  f:Raise()
  if default then f.edit:SetFocus(); f.edit:HighlightText() end
end

-- Right-click a position: confirm, then leave it out of the portfolio.
local function AskExclude(r)
  local id, name = r.itemID, r.name
  if not id then return end
  Ask("Exclude " .. name .. " from the portfolio?\n\nIt stops counting toward totals, categories and rules."
    .. " Its history is kept; /ledger include " .. id .. " brings it back.", nil, function()
    if ns.SetExcluded(id, true) then ns.Print(name .. " excluded from the portfolio.") end
  end)
end

-- Right-click > Mark as used: ask how many (pre-filled with the counted
-- shortfall, else the whole position), then use them up at average cost.
local function AskUse(r)
  local id, name = r.itemID, r.name
  if not id then return end
  local default = r.missing or r.qty
  local prof = ns.MainCraftProf()
  Ask("How many " .. name .. " did you use for " .. prof .. "?\n\nThey leave the portfolio at average cost"
    .. " (no profit or loss) and count toward " .. prof .. " spending.", default, function(n)
    if not ns.Consume(id, n, prof) then
      ns.Print("couldn't mark " .. name .. " as used (no recorded quantity?).")
    end
  end)
end

-- Small right-click menu for a position row.
local rowMenu
local function ShowRowMenu(row)
  local r = row.data
  if not r then return end
  if not rowMenu then
    rowMenu = CreateFrame("Frame", "LedgerRowMenu", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    rowMenu:SetFrameStrata("FULLSCREEN_DIALOG")
    rowMenu:SetClampedToScreen(true)
    rowMenu:EnableMouse(true)
    if rowMenu.SetBackdrop then
      rowMenu:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = {left = 3, right = 3, top = 3, bottom = 3},
      })
      rowMenu:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
    else
      local bg = Tex(rowMenu, "BACKGROUND", {0.05, 0.05, 0.07}, 0.95)
      bg:SetAllPoints()
    end
    rowMenu.title = FS(rowMenu, "GameFontNormalSmall", "LEFT", 200)
    rowMenu.title:SetPoint("TOPLEFT", 8, -7)
    rowMenu.items = {}
    local labels = {"use", "exclude", "cancel"}
    for i, key in ipairs(labels) do
      local b = CreateFrame("Button", nil, rowMenu)
      b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
      b:SetSize(200, 16)
      b:SetPoint("TOPLEFT", 6, -6 - i * 16)
      b.text = FS(b, "GameFontHighlightSmall", "LEFT", 196)
      b.text:SetPoint("LEFT", 2, 0)
      local hl = Tex(b, "HIGHLIGHT", {1, 1, 1}, 0.15)
      hl:SetAllPoints()
      rowMenu.items[key] = b
    end
    rowMenu.items.cancel.text:SetText(GREY .. (CANCEL or "Cancel") .. "|r")
    rowMenu.items.cancel:SetScript("OnClick", function() rowMenu:Hide() end)
    rowMenu:SetSize(212, 6 + 4 * 16 + 8)
    -- close when the portfolio window closes, or on a click outside the menu
    if frame then frame:HookScript("OnHide", function() rowMenu:Hide() end) end
    -- Close on a click outside the menu. The check runs a frame later and
    -- uses the native IsMouseOver: hiding on the mouse-down itself (or a
    -- missing/false MouseIsOver) hid the menu before its buttons got the
    -- mouse-up, so clicking an option silently did nothing.
    pcall(rowMenu.RegisterEvent, rowMenu, "GLOBAL_MOUSE_DOWN")
    rowMenu:SetScript("OnEvent", function(self)
      if not self:IsShown() then return end
      local function check()
        if self:IsShown() and not self:IsMouseOver() then self:Hide() end
      end
      if C_Timer and C_Timer.After then C_Timer.After(0.05, check) else check() end
    end)
    if UISpecialFrames then table.insert(UISpecialFrames, "LedgerRowMenu") end
  end
  rowMenu.title:SetText(r.name)
  rowMenu.items.use.text:SetText(r.missing
    and (ORANGE .. "Mark " .. r.missing .. " as used (" .. ns.MainCraftProf() .. ")...|r")
    or "Mark as used (" .. ns.MainCraftProf() .. ")...")
  rowMenu.items.use:SetScript("OnClick", function() rowMenu:Hide(); Safe(AskUse, r) end)
  rowMenu.items.exclude.text:SetText("Exclude from portfolio...")
  rowMenu.items.exclude:SetScript("OnClick", function() rowMenu:Hide(); Safe(AskExclude, r) end)
  local x, y = GetCursorPosition()
  local s = UIParent:GetEffectiveScale()
  rowMenu:ClearAllPoints()
  rowMenu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / s, y / s)
  rowMenu:Show()
end

local SPARK_N, SPARK_BW, SPARK_H = 7, 4, 12

local function MakeRow(i)
  local row = CreateFrame("Frame", nil, content)
  row:SetSize(CW - 20, ROW_H)
  row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * ROW_H)
  row:EnableMouse(true)
  row.stripe = Tex(row, "BACKGROUND", {1, 1, 1}, (i % 2 == 0) and 0.04 or 0)
  row.stripe:SetAllPoints()
  row.hl = Tex(row, "HIGHLIGHT", {1, 1, 1}, 0.10)
  row.hl:SetAllPoints()
  row.cells = {}
  for _, col in ipairs(COLS) do
    if col.key ~= "bar" then
      local fs = FS(row, "GameFontHighlightSmall", col.j, col.w)
      fs:SetPoint("LEFT", row, "LEFT", col.x, 0)
      row.cells[col.key] = fs
    end
  end
  -- diverging gain bar
  local bc = COL_BY_KEY.bar
  row.barMid = Tex(row, "ARTWORK", C.grey, 0.6)
  row.barMid:SetSize(1, ROW_H - 4)
  row.barMid:SetPoint("LEFT", row, "LEFT", bc.x + bc.w / 2, 0)
  row.bar = Tex(row, "ARTWORK", C.green, 0.9)
  row.bar:SetHeight(ROW_H - 8)
  -- sparkline: SPARK_N small columns, then % text in the trend cell
  local tc = COL_BY_KEY.trend
  row.spark = {}
  for s = 1, SPARK_N do
    local t = Tex(row, "ARTWORK", C.bar, 0.9)
    t:SetWidth(SPARK_BW)
    t:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", tc.x + (s - 1) * (SPARK_BW + 1), 2)
    row.spark[s] = t
  end
  row.cells.trend:ClearAllPoints()
  row.cells.trend:SetPoint("LEFT", row, "LEFT", tc.x + SPARK_N * (SPARK_BW + 1) + 3, 0)
  row.cells.trend:SetWidth(tc.w - SPARK_N * (SPARK_BW + 1) - 3)
  row:SetScript("OnEnter", RowTooltip)
  row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  row:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" and self.data then ShowRowMenu(self) end
  end)
  rowPool[i] = row
  return row
end

local function FillRow(row, r, maxAbsPct)
  row.data = r
  local cells = row.cells
  local nameCol = r.sell and GREEN or ""
  cells.name:SetText(nameCol .. r.name .. "|r")
  cells.category:SetText(GREY .. r.category .. "|r")
  local qty = tostring(r.qty)
  if (r.auctions or 0) > 0 then qty = qty .. GREY .. " (" .. r.auctions .. " AH)|r" end
  if r.have and r.have ~= r.qty then qty = qty .. ORANGE .. "*|r" end
  cells.qty:SetText(qty)
  cells.price:SetText(r.price and M(r.price) or (GREY .. "no data|r"))
  cells.cost:SetText(M(r.cost))
  cells.value:SetText(r.value and M(r.value) or "-")
  local gc = GainColor(r.gain)
  cells.gain:SetText(r.gain and (gc .. M(r.gain) .. "|r") or "-")
  cells.pct:SetText(r.pct and (gc .. Pct(r.pct, true) .. "|r") or "-")

  -- gain bar
  local bc = COL_BY_KEY.bar
  local half = bc.w / 2 - 2
  row.bar:ClearAllPoints()
  if r.pct and maxAbsPct > 0 then
    local w = math.max(1, math.min(half, half * math.abs(r.pct) / maxAbsPct))
    row.bar:SetWidth(w)
    if r.pct >= 0 then
      row.bar:SetPoint("LEFT", row, "LEFT", bc.x + bc.w / 2 + 1, 0)
      SetTexColor(row.bar, C.green, 0.9)
    else
      row.bar:SetPoint("RIGHT", row, "LEFT", bc.x + bc.w / 2, 0)
      SetTexColor(row.bar, C.red, 0.9)
    end
    row.bar:Show()
  else
    row.bar:Hide()
  end

  -- sparkline
  local spark = r.spark or {}
  local lo, hi
  for _, e in ipairs(spark) do
    lo = (lo == nil or e.min < lo) and e.min or lo
    hi = (hi == nil or e.min > hi) and e.min or hi
  end
  local offset = SPARK_N - #spark
  for s = 1, SPARK_N do
    local t = row.spark[s]
    local e = spark[s - offset]
    if e and lo and hi then
      local frac = (hi > lo) and (e.min - lo) / (hi - lo) or 0.5
      t:SetHeight(2 + frac * (SPARK_H - 2))
      t:Show()
    else
      t:Hide()
    end
  end
  if r.trend then
    cells.trend:SetText(GainColor(r.trend) .. string.format("%+.0f%%", r.trend * 100) .. "|r")
  else
    cells.trend:SetText(GREY .. (#spark == 1 and "1 day" or "-") .. "|r")
  end

  local tags = {}
  if r.sell then table.insert(tags, GREEN .. "SELL|r") end
  if r.cap then table.insert(tags, ORANGE .. "CAP|r") end
  if r.missing then table.insert(tags, ORANGE .. "USED?|r") end
  cells.tags:SetText(table.concat(tags, " "))
  row:Show()
end

------------------------------------------------------------------------
-- frame
------------------------------------------------------------------------

local function SavePosition(self)
  local point, _, relPoint, x, y = self:GetPoint()
  ns.db.ui.point = {point, relPoint, x, y}
end

local function OnHeaderClick(self)
  local ui = ns.db.ui
  local key = self.col.key
  if ui.sortKey == key then
    ui.sortAsc = not ui.sortAsc
  else
    ui.sortKey = key
    ui.sortAsc = self.col.str and true or false
  end
  ns.RefreshUI()
end

local function CreateUI()
  frame = CreateFrame("Frame", "LedgerFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  frame:SetSize(W, H)
  frame:SetFrameStrata("DIALOG")
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SavePosition(self)
  end)
  if frame.SetBackdrop then
    frame:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 16,
      insets = {left = 4, right = 4, top = 4, bottom = 4},
    })
  else
    local bg = Tex(frame, "BACKGROUND", {0.05, 0.05, 0.07}, 0.92)
    bg:SetAllPoints()
  end
  local p = ns.db.ui.point
  if type(p) == "table" and p[1] then
    frame:SetPoint(p[1], UIParent, p[2] or p[1], p[3] or 0, p[4] or 0)
  else
    frame:SetPoint("CENTER")
  end

  frame.title = FS(frame, "GameFontNormalLarge", "LEFT")
  frame.title:SetPoint("TOPLEFT", PAD, -10)
  frame.title:SetText("Ledger")

  frame.fresh = FS(frame, "GameFontHighlightSmall", "RIGHT", 300)
  frame.fresh:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -112, -14)

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)

  local snap = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  snap:SetSize(70, 20)
  snap:SetPoint("TOPRIGHT", -34, -8)
  snap:SetText("Snap")
  snap:SetScript("OnClick", function() SlashCmdList["LEDGER"]("snap") end)

  frame.takeaway = FS(frame, "GameFontHighlightSmall", "LEFT", CW)
  frame.takeaway:SetPoint("TOPLEFT", PAD, -36)

  local labels = {"Total wealth", "Cash", "Holdings (market)", "Cost basis", "Unrealized*", "Realized", "Positions"}
  for i, l in ipairs(labels) do tiles[i] = MakeTile(i, l) end

  frame.allocTitle = FS(frame, "GameFontNormalSmall", "LEFT")
  frame.allocTitle:SetText("Allocation by category (share of market value)")
  frame.allocNote = FS(frame, "GameFontDisableSmall", "LEFT", CW)

  -- table header
  frame.header = CreateFrame("Frame", nil, frame)
  frame.header:SetSize(CW, ROW_H + 2)
  for _, col in ipairs(COLS) do
    local b = CreateFrame("Button", nil, frame.header)
    b:SetSize(col.w, ROW_H)
    b:SetPoint("LEFT", frame.header, "LEFT", col.x, 0)
    b.text = FS(b, "GameFontNormalSmall", col.j, col.w)
    b.text:SetAllPoints()
    b.col = col
    b:SetScript("OnClick", OnHeaderClick)
    local hl = Tex(b, "HIGHLIGHT", {1, 1, 1}, 0.12)
    hl:SetAllPoints()
    headerBtns[col.key] = b
  end
  local line = Tex(frame.header, "ARTWORK", C.gold, 0.4)
  line:SetHeight(1)
  line:SetPoint("BOTTOMLEFT", 0, 0)
  line:SetPoint("BOTTOMRIGHT", 0, 0)

  -- scrolling table body
  local ok, sf = pcall(CreateFrame, "ScrollFrame", "LedgerScrollFrame", frame, "UIPanelScrollFrameTemplate")
  if not ok or not sf then
    sf = CreateFrame("ScrollFrame", "LedgerScrollFrame", frame)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
      local maxV = math.max(0, content:GetHeight() - self:GetHeight())
      local v = math.min(maxV, math.max(0, self:GetVerticalScroll() - delta * ROW_H * 3))
      self:SetVerticalScroll(v)
    end)
  end
  scroll = sf
  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(CW - 20, ROW_H)
  scroll:SetScrollChild(content)

  frame.footer = FS(frame, "GameFontHighlightSmall", "LEFT", CW)
  frame.footer:SetPoint("BOTTOMLEFT", PAD, 26)
  frame.footer2 = FS(frame, "GameFontDisableSmall", "LEFT", CW)
  frame.footer2:SetPoint("BOTTOMLEFT", PAD, 12)

  -- tabs
  frame.tabs = {}
  local tabDefs = {{key = "portfolio", label = "Portfolio", w = 80}, {key = "vendor", label = "Below vendor", w = 100},
    {key = "bank", label = "Bank value", w = 90}, {key = "craft", label = "Crafting", w = 70}}
  local tx = PAD + 70
  for _, t in ipairs(tabDefs) do
    local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    b:SetSize(t.w, 20)
    b:SetPoint("TOPLEFT", frame, "TOPLEFT", tx, -8)
    b:SetText(t.label)
    b:SetScript("OnClick", function()
      ns.db.ui.tab = t.key
      ns.RefreshUI()
    end)
    frame.tabs[t.key] = b
    tx = tx + t.w + 4
  end

  if ns.CreateVendorPane then ns.CreateVendorPane(frame) end
  if ns.CreateBankPane then ns.CreateBankPane(frame) end
  if ns.CreateCraftPane then ns.CreateCraftPane(frame) end

  if UISpecialFrames then table.insert(UISpecialFrames, "LedgerFrame") end
  frame:SetScript("OnShow", function() ns.RefreshUI() end)
  frame:Hide()
end

------------------------------------------------------------------------
-- tab switching
------------------------------------------------------------------------

local function CurrentTab()
  local t = ns.db.ui.tab
  return (t == "vendor" or t == "bank" or t == "craft") and t or "portfolio"
end

local function ApplyTab(tab)
  local showP = (tab == "portfolio")
  local widgets = {frame.takeaway, frame.allocTitle, frame.allocNote, frame.header, scroll,
    frame.footer, frame.footer2}
  for _, t in ipairs(tiles) do widgets[#widgets + 1] = t end
  for _, w in ipairs(widgets) do
    if showP then w:Show() else w:Hide() end
  end
  if not showP then
    for _, r in ipairs(catRows) do ShowCatRow(r, false) end
  end
  if frame.vendorPane then
    if tab == "vendor" then frame.vendorPane:Show() else frame.vendorPane:Hide() end
  end
  if frame.bankPane then
    if tab == "bank" then frame.bankPane:Show() else frame.bankPane:Hide() end
  end
  if frame.craftPane then
    if tab == "craft" then frame.craftPane:Show() else frame.craftPane:Hide() end
  end
  for key, b in pairs(frame.tabs) do
    if key == tab then b:LockHighlight() else b:UnlockHighlight() end
  end
end

------------------------------------------------------------------------
-- "Below vendor" tab: AH listings priced under what a vendor pays
------------------------------------------------------------------------

local VCOLS = {
  {key = "name",      label = "Item",         w = 200, j = "LEFT",  str = true},
  {key = "ah",        label = "AH lowest",    w = 76,  j = "RIGHT"},
  {key = "vendor",    label = "Vendor pays",  w = 76,  j = "RIGHT"},
  {key = "gain",      label = "Gain each",    w = 72,  j = "RIGHT"},
  {key = "gpct",      label = "Gain %",       w = 52,  j = "RIGHT"},
  {key = "atMin",     label = "At price",     w = 76,  j = "RIGHT"},
  {key = "under",     label = "Under vendor", w = 82,  j = "RIGHT"},
  {key = "underGain", label = "Total gain",   w = 76,  j = "RIGHT"},
  {key = "age",       label = "Seen",         w = 56,  j = "RIGHT"},
}
do
  local x = 0
  for _, col in ipairs(VCOLS) do col.x = x; x = x + col.w + COL_GAP end
end
local VRECOMPUTE_SECONDS = 30
local vRows, vHeaderBtns = {}, {}
local vScroll, vContent
local vNameRetry, vNameTries = false, 0

-- name (and clickable link) if the client has the item loaded
local function ItemNameLink(id)
  local name, link = ns.ItemInfo(id)
  return name, link
end

-- Alt-click: AuctionDB's price history graph for the item (same as Alt-clicking it in your bags). true if shown.
local function AltGraph(id)
  if not (id and IsAltKeyDown and IsAltKeyDown()) then return false end
  local adb = _G.AuctionDB
  if adb and adb.ShowItem then
    local ok, err = pcall(adb.ShowItem, adb, id)
    if not ok then print("|cff33ff99Ledger|r: AuctionDB graph failed: " .. tostring(err)) end
  else
    print("|cff33ff99Ledger|r: Alt-click opens AuctionDB's price graph, but AuctionDB isn't loaded.")
  end
  return true
end

local function VRowTooltip(row)
  local r = row.data
  if not r or not GameTooltip then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  if GameTooltip.SetItemByID then
    GameTooltip:SetItemByID(r.id)
  else
    GameTooltip:SetHyperlink("item:" .. r.id)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine("AH lowest buyout", M(r.ah), 1, 1, 1, 1, 1, 1)
  GameTooltip:AddDoubleLine("Vendor pays", M(r.vendor), 1, 1, 1, 1, 1, 1)
  GameTooltip:AddDoubleLine("Gain per item", M(r.gain), 1, 1, 1, C.green[1], C.green[2], C.green[3])
  local levels = ns.ListingLevels and ns.ListingLevels(r.id)
  if levels then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Cheapest listings (last full scan)", 1, 0.82, 0)
    for i, l in ipairs(levels) do
      if i > 8 then GameTooltip:AddLine("  ... " .. (#levels - 8) .. " more price levels", 0.6, 0.6, 0.6); break end
      local under = l[1] < r.vendor
      GameTooltip:AddDoubleLine(string.format("  %s each", M(l[1])), string.format("%d listing%s, %d units",
        l[2], l[2] == 1 and "" or "s", l[3]), 1, 1, 1, unpack(under and C.green or {0.6, 0.6, 0.6}))
    end
    if r.under then
      GameTooltip:AddDoubleLine("Buy all " .. r.under .. " under vendor", M(r.underCost), 1, 1, 1, 1, 1, 1)
      GameTooltip:AddDoubleLine("Vendor them for", M(r.underCost + r.underGain) .. "  (+" .. M(r.underGain) .. ")",
        1, 1, 1, C.green[1], C.green[2], C.green[3])
    end
  else
    GameTooltip:AddLine("Listing counts come from AHDB's next full scan.", 0.6, 0.6, 0.6)
  end
  GameTooltip:AddLine("Click: show it in the AH to buy" .. (r.under and (" (quantity starts at " .. r.under .. ")") or ""),
    0.6, 0.6, 0.6)
  GameTooltip:AddLine("Shift-click: link in chat.  Alt-click: AuctionDB price graph", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

local function MakeVRow(i)
  local row = CreateFrame("Button", nil, vContent)
  row:SetSize(CW - 20, ROW_H)
  row:SetPoint("TOPLEFT", vContent, "TOPLEFT", 0, -(i - 1) * ROW_H)
  row.stripe = Tex(row, "BACKGROUND", {1, 1, 1}, (i % 2 == 0) and 0.04 or 0)
  row.stripe:SetAllPoints()
  row.hl = Tex(row, "HIGHLIGHT", {1, 1, 1}, 0.10)
  row.hl:SetAllPoints()
  row.cells = {}
  for _, col in ipairs(VCOLS) do
    local fs = FS(row, "GameFontHighlightSmall", col.j, col.w)
    fs:SetPoint("LEFT", row, "LEFT", col.x, 0)
    row.cells[col.key] = fs
  end
  row:SetScript("OnEnter", VRowTooltip)
  row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  row:SetScript("OnClick", function(self)
    local r = self.data
    if not r then return end
    if AltGraph(r.id) then return end
    local _, link = ItemNameLink(r.id)
    if IsModifiedClick and IsModifiedClick("CHATLINK") then
      if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
      return
    end
    -- click: open it in the AH's buy view (you still choose the quantity and click Buy)
    if ns.ShowInAH then ns.ShowInAH(r.id, r.ah, r.under) end
  end)
  vRows[i] = row
  return row
end

local function OnVHeaderClick(self)
  local ui = ns.db.ui
  local key = self.col.key
  if ui.vSortKey == key then
    ui.vSortAsc = not ui.vSortAsc
  else
    ui.vSortKey = key
    ui.vSortAsc = self.col.str and true or false
  end
  ns.RefreshUI()
end

function ns.CreateVendorPane(parent)
  local p = CreateFrame("Frame", nil, parent)
  p:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -36)
  p:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -PAD, 8)
  parent.vendorPane = p

  p.summary = FS(p, "GameFontHighlightSmall", "LEFT", CW - 110)
  p.summary:SetPoint("TOPLEFT", 0, -4)

  local check = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  check:SetSize(100, 20)
  check:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, 0)
  check:SetText("Check now")
  check:SetScript("OnClick", function()
    if not (Auctionator and Auctionator.API) then return end
    p.status = "checking"
    ns.RefreshUI()
    local started = ns.ScanVendorPrices(function(missing)
      p.status = nil
      p.missing = missing
      ns.BelowVendor()
      ns.RefreshUI()
    end)
    if not started and not ns.VendorRunning() then
      p.status = "noscan"
      ns.RefreshUI()
    end
  end)

  p.header = CreateFrame("Frame", nil, p)
  p.header:SetSize(CW, ROW_H + 2)
  p.header:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -30)
  for _, col in ipairs(VCOLS) do
    local b = CreateFrame("Button", nil, p.header)
    b:SetSize(col.w, ROW_H)
    b:SetPoint("LEFT", p.header, "LEFT", col.x, 0)
    b.text = FS(b, "GameFontNormalSmall", col.j, col.w)
    b.text:SetAllPoints()
    b.col = col
    b:SetScript("OnClick", OnVHeaderClick)
    local hl = Tex(b, "HIGHLIGHT", {1, 1, 1}, 0.12)
    hl:SetAllPoints()
    vHeaderBtns[col.key] = b
  end
  local line = Tex(p.header, "ARTWORK", C.gold, 0.4)
  line:SetHeight(1)
  line:SetPoint("BOTTOMLEFT", 0, 0)
  line:SetPoint("BOTTOMRIGHT", 0, 0)

  local ok, sf = pcall(CreateFrame, "ScrollFrame", "LedgerVendorScrollFrame", p, "UIPanelScrollFrameTemplate")
  if not ok or not sf then
    sf = CreateFrame("ScrollFrame", "LedgerVendorScrollFrame", p)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
      local maxV = math.max(0, vContent:GetHeight() - self:GetHeight())
      self:SetVerticalScroll(math.min(maxV, math.max(0, self:GetVerticalScroll() - delta * ROW_H * 3)))
    end)
  end
  vScroll = sf
  vScroll:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -30 - ROW_H - 4)
  vScroll:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -22, 36)
  vContent = CreateFrame("Frame", nil, vScroll)
  vContent:SetSize(CW - 20, ROW_H)
  vScroll:SetScrollChild(vContent)

  p.empty = FS(vContent, "GameFontHighlightSmall", "LEFT", CW - 20)
  p.empty:SetPoint("TOPLEFT", 0, -2)

  p.footer = FS(p, "GameFontDisableSmall", "LEFT", CW)
  p.footer:SetPoint("BOTTOMLEFT", 0, 18)
  p.footer:SetText("At price = listings (units) at the lowest buyout. Under vendor = units priced below vendor;"
    .. " Total gain = vendoring them all. From the last full AHDB scan.")
  p.footer2 = FS(p, "GameFontDisableSmall", "LEFT", CW)
  p.footer2:SetPoint("BOTTOMLEFT", 0, 4)
  p.footer2:SetText("Click a row to open it in the AH's buy view (you click Buy).  Shift-click to link it."
    .. "  /ledger vendor prints the list in chat.")
  p:Hide()
end

local function RefreshVendor()
  local p = frame.vendorPane
  if not p then return end
  local db = ns.db
  local bv = db.belowVendor
  -- recompute from saved vendor prices if the saved list is old (cheap enough
  -- to do on view, but not on every bag update)
  if db.vendor and not ns.VendorRunning() and (not bv or (time() - (bv.t or 0)) > VRECOMPUTE_SECONDS) then
    ns.BelowVendor()
    bv = db.belowVendor
  end
  local items = (bv and bv.items) or {}

  local known = 0
  for _ in pairs(db.vendor or {}) do known = known + 1 end

  -- summary
  local parts = {}
  if ns.VendorRunning() or p.status == "checking" then
    table.insert(parts, ORANGE .. "Checking vendor prices...|r")
  elseif p.status == "noscan" then
    table.insert(parts, ORANGE .. "No scan data yet - do a full AHDB or Auctionator scan first.|r")
  end
  if not (Auctionator and Auctionator.API) and not ns.HasAHDB() then
    table.insert(parts, RED .. "no AHDB or Auctionator - no prices|r")
  end
  if known == 0 then
    table.insert(parts, GREY .. "Vendor prices not looked up yet - press Check now.|r")
  else
    table.insert(parts, (#items > 0 and GREEN or "") .. #items .. " item" .. (#items == 1 and "" or "s")
      .. " below vendor price|r")
    if bv and bv.t then table.insert(parts, GREY .. "checked " .. Ago(bv.t) .. "|r") end
    table.insert(parts, GREY .. "vendor prices known for " .. known .. " items|r")
    local total, cost = 0, 0
    for _, it in ipairs(items) do
      if it.underGain then total, cost = total + it.underGain, cost + (it.underCost or 0) end
    end
    if total > 0 then
      table.insert(parts, "buy all for " .. M(cost) .. ", vendor for " .. GREEN .. "+" .. M(total) .. "|r")
    end
    local lt = db.listings and db.listings.t
    table.insert(parts, GREY .. (lt and ("listings from scan " .. Ago(lt)) or "listing counts after next AHDB scan") .. "|r")
    if (p.missing or 0) > 0 then table.insert(parts, ORANGE .. p.missing .. " still loading|r") end
  end
  p.summary:SetText(table.concat(parts, "  |  "))

  -- rows (copy so sorting doesn't reorder the saved list)
  local rows = {}
  local missingName = false
  for _, it in ipairs(items) do
    local name = ItemNameLink(it.id)
    if not name then missingName = true end
    rows[#rows + 1] = {id = it.id, name = name or it.name or ("item " .. it.id), ah = it.ah, vendor = it.vendor,
      gain = it.gain, gpct = (it.ah and it.ah > 0) and (it.gain / it.ah) or nil, age = it.age,
      atMin = it.atMin, atMinUnits = it.atMinUnits, under = it.under, underCost = it.underCost,
      underGain = it.underGain}
  end
  local ui = db.ui
  local key = ui.vSortKey or "gain"
  local asc = ui.vSortAsc and true or false
  table.sort(rows, function(a, b)
    local va, vb = a[key], b[key]
    if key == "name" then va, vb = lower(va), lower(vb) end
    if va == nil and vb == nil then return a.id < b.id end
    if va == nil then return false end
    if vb == nil then return true end
    if va == vb then return a.id < b.id end
    if asc then return va < vb end
    return va > vb
  end)
  for k, b in pairs(vHeaderBtns) do
    b.text:SetText(b.col.label .. ((k == key) and (asc and " ^" or " v") or ""))
  end

  for i, r in ipairs(rows) do
    local row = vRows[i] or MakeVRow(i)
    row.data = r
    local c = row.cells
    c.name:SetText(r.name)
    c.ah:SetText(M(r.ah))
    c.vendor:SetText(M(r.vendor))
    c.gain:SetText(GREEN .. "+" .. M(r.gain) .. "|r")
    c.gpct:SetText(r.gpct and (GREEN .. Pct(r.gpct, true) .. "|r") or "-")
    c.age:SetText(GREY .. ((r.age == 0 or r.age == nil) and "today" or (r.age .. "d ago")) .. "|r")
    -- "3 (60)" = 3 listings, 60 units at the lowest price
    c.atMin:SetText(r.atMin and (r.atMin .. GREY .. " (" .. r.atMinUnits .. ")|r") or (GREY .. "-|r"))
    c.under:SetText(r.under and tostring(r.under) or (GREY .. "-|r"))
    c.underGain:SetText(r.underGain and (GREEN .. "+" .. M(r.underGain) .. "|r") or (GREY .. "-|r"))
    row:Show()
  end
  for i = #rows + 1, #vRows do vRows[i]:Hide(); vRows[i].data = nil end
  vContent:SetHeight(math.max(ROW_H, #rows * ROW_H))
  if #rows == 0 then
    p.empty:SetText(GREY .. (known == 0 and "Nothing checked yet." or "Nothing is listed below vendor price right now.")
      .. "|r")
    p.empty:Show()
  else
    p.empty:Hide()
  end

  -- names load asynchronously; redraw once shortly after asking for them
  if not missingName then vNameTries = 0 end
  if missingName and not vNameRetry and vNameTries < 5 then
    vNameRetry = true
    vNameTries = vNameTries + 1
    C_Timer.After(1, function() vNameRetry = false; ns.RefreshUI() end)
  end
end

------------------------------------------------------------------------
-- "Bank value" tab: everything in the bank (optionally bags) at AH price,
-- or vendor price for soulbound / unlisted items
------------------------------------------------------------------------

local BCOLS = {
  {key = "name",  label = "Item",      w = 300, j = "LEFT",  str = true},
  {key = "n",     label = "Qty",       w = 70,  j = "RIGHT"},
  {key = "each",  label = "Each",      w = 100, j = "RIGHT"},
  {key = "value", label = "Value",     w = 110, j = "RIGHT"},
  {key = "how",   label = "Priced by", w = 100, j = "RIGHT", str = true},
  {key = "age",   label = "Seen",      w = 90,  j = "RIGHT"},
}
do
  local x = 0
  for _, col in ipairs(BCOLS) do col.x = x; x = x + col.w + COL_GAP end
end
local bRows, bHeaderBtns = {}, {}
local bScroll, bContent
local bNameRetry, bNameTries = false, 0

local function BRowTooltip(row)
  local r = row.data
  if not r or not GameTooltip then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  if GameTooltip.SetItemByID then GameTooltip:SetItemByID(r.id) else GameTooltip:SetHyperlink("item:" .. r.id) end
  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine("Count", tostring(r.n), 1, 1, 1, 1, 1, 1)
  GameTooltip:AddDoubleLine("AH lowest buyout", r.bound and "soulbound" or (r.ah and M(r.ah) or "no price"),
    1, 1, 1, 1, 1, 1)
  GameTooltip:AddDoubleLine("Vendor pays", r.vendor and M(r.vendor) or "?", 1, 1, 1, 1, 1, 1)
  if r.value then GameTooltip:AddDoubleLine("Value", M(r.value), 1, 1, 1, C.gold[1], C.gold[2], C.gold[3]) end
  if r.how == "ah" and r.ah then
    GameTooltip:AddDoubleLine("After 5% AH cut", M(floor(r.ah * r.n * 0.95)), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
  end
  GameTooltip:AddLine("Shift-click: link in chat.  Alt-click: AuctionDB price graph", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

local function MakeBRow(i)
  local row = CreateFrame("Button", nil, bContent)
  row:SetSize(CW - 20, ROW_H)
  row:SetPoint("TOPLEFT", bContent, "TOPLEFT", 0, -(i - 1) * ROW_H)
  row.stripe = Tex(row, "BACKGROUND", {1, 1, 1}, (i % 2 == 0) and 0.04 or 0)
  row.stripe:SetAllPoints()
  row.hl = Tex(row, "HIGHLIGHT", {1, 1, 1}, 0.10)
  row.hl:SetAllPoints()
  row.cells = {}
  for _, col in ipairs(BCOLS) do
    local fs = FS(row, "GameFontHighlightSmall", col.j, col.w)
    fs:SetPoint("LEFT", row, "LEFT", col.x, 0)
    row.cells[col.key] = fs
  end
  row:SetScript("OnEnter", BRowTooltip)
  row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  row:SetScript("OnClick", function(self)
    local r = self.data
    if not r then return end
    if AltGraph(r.id) then return end
    local _, link = ItemNameLink(r.id)
    if link and IsModifiedClick and IsModifiedClick("CHATLINK") and ChatEdit_InsertLink then
      ChatEdit_InsertLink(link)
    end
  end)
  bRows[i] = row
  return row
end

local function OnBHeaderClick(self)
  local ui = ns.db.ui
  local key = self.col.key
  if ui.bSortKey == key then
    ui.bSortAsc = not ui.bSortAsc
  else
    ui.bSortKey = key
    ui.bSortAsc = self.col.str and true or false
  end
  ns.RefreshUI()
end

function ns.CreateBankPane(parent)
  local p = CreateFrame("Frame", nil, parent)
  p:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -36)
  p:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -PAD, 8)
  parent.bankPane = p

  p.summary = FS(p, "GameFontHighlightSmall", "LEFT", CW - 130)
  p.summary:SetPoint("TOPLEFT", 0, -4)

  local bagsBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  bagsBtn:SetSize(120, 20)
  bagsBtn:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, 0)
  bagsBtn:SetScript("OnClick", function()
    ns.db.ui.bankBags = not ns.db.ui.bankBags
    ns.RefreshUI()
  end)
  p.bagsBtn = bagsBtn

  p.header = CreateFrame("Frame", nil, p)
  p.header:SetSize(CW, ROW_H + 2)
  p.header:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -30)
  for _, col in ipairs(BCOLS) do
    local b = CreateFrame("Button", nil, p.header)
    b:SetSize(col.w, ROW_H)
    b:SetPoint("LEFT", p.header, "LEFT", col.x, 0)
    b.text = FS(b, "GameFontNormalSmall", col.j, col.w)
    b.text:SetAllPoints()
    b.col = col
    b:SetScript("OnClick", OnBHeaderClick)
    local hl = Tex(b, "HIGHLIGHT", {1, 1, 1}, 0.12)
    hl:SetAllPoints()
    bHeaderBtns[col.key] = b
  end
  local line = Tex(p.header, "ARTWORK", C.gold, 0.4)
  line:SetHeight(1)
  line:SetPoint("BOTTOMLEFT", 0, 0)
  line:SetPoint("BOTTOMRIGHT", 0, 0)

  local ok, sf = pcall(CreateFrame, "ScrollFrame", "LedgerBankScrollFrame", p, "UIPanelScrollFrameTemplate")
  if not ok or not sf then
    sf = CreateFrame("ScrollFrame", "LedgerBankScrollFrame", p)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
      local maxV = math.max(0, bContent:GetHeight() - self:GetHeight())
      self:SetVerticalScroll(math.min(maxV, math.max(0, self:GetVerticalScroll() - delta * ROW_H * 3)))
    end)
  end
  bScroll = sf
  bScroll:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -30 - ROW_H - 4)
  bScroll:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -22, 36)
  bContent = CreateFrame("Frame", nil, bScroll)
  bContent:SetSize(CW - 20, ROW_H)
  bScroll:SetScrollChild(bContent)

  p.empty = FS(bContent, "GameFontHighlightSmall", "LEFT", CW - 20)
  p.empty:SetPoint("TOPLEFT", 0, -2)

  p.footer = FS(p, "GameFontDisableSmall", "LEFT", CW)
  p.footer:SetPoint("BOTTOMLEFT", 0, 18)
  p.footer:SetText("Value = AH lowest buyout x count, or the vendor price for soulbound items and items with no AH"
    .. " price. Before the 5% AH cut.")
  p.footer2 = FS(p, "GameFontDisableSmall", "LEFT", CW)
  p.footer2:SetPoint("BOTTOMLEFT", 0, 4)
  p.footer2:SetText("The bank is recorded each time you open it.  Hover a row for details; shift-click to link it.")
  p:Hide()
end

local function RefreshBank()
  local p = frame.bankPane
  if not p then return end
  local db = ns.db
  local withBags = db.ui.bankBags and true or false
  p.bagsBtn:SetText(withBags and "Bank + bags" or "Bank only")
  local d = ns.BankValue(withBags)

  local parts = {}
  if not d.bankT then
    table.insert(parts, ORANGE .. "Open your bank once to record what's in it.|r")
  else
    table.insert(parts, "Total " .. GOLD .. M(d.total) .. "|r")
    table.insert(parts, "AH " .. M(d.ahTotal))
    table.insert(parts, "vendor " .. M(d.vendorTotal))
    table.insert(parts, GREY .. #d.rows .. " items|r")
    if d.unpriced > 0 then table.insert(parts, GREY .. d.unpriced .. " unpriced|r") end
    table.insert(parts, GREY .. "bank seen " .. Ago(d.bankT) .. "|r")
  end
  if not (Auctionator and Auctionator.API) and not ns.HasAHDB() then table.insert(parts, RED .. "no AHDB or Auctionator - no prices|r") end
  p.summary:SetText(table.concat(parts, "  |  "))

  local missingName = d.loading > 0
  for _, r in ipairs(d.rows) do
    local name = ItemNameLink(r.id) or r.savedName
    if not name then missingName = true end
    r.name = name or ("item " .. r.id)
  end
  local ui = db.ui
  local key = ui.bSortKey or "value"
  local asc = ui.bSortAsc and true or false
  table.sort(d.rows, function(a, b)
    local va, vb = a[key], b[key]
    if key == "name" or key == "how" then va, vb = va and lower(va), vb and lower(vb) end
    if va == nil and vb == nil then return a.id < b.id end
    if va == nil then return false end
    if vb == nil then return true end
    if va == vb then return a.id < b.id end
    if asc then return va < vb end
    return va > vb
  end)
  for k, b in pairs(bHeaderBtns) do
    b.text:SetText(b.col.label .. ((k == key) and (asc and " ^" or " v") or ""))
  end

  for i, r in ipairs(d.rows) do
    local row = bRows[i] or MakeBRow(i)
    row.data = r
    local c = row.cells
    c.name:SetText(r.name)
    c.n:SetText(tostring(r.n))
    c.each:SetText(r.each and M(r.each) or (GREY .. "-|r"))
    c.value:SetText(r.value and M(r.value) or (GREY .. "-|r"))
    c.how:SetText(r.how == "ah" and "AH" or (r.how == "vendor" and (GREY .. (r.bound and "vendor (bound)" or "vendor")
      .. "|r") or (GREY .. "none|r")))
    if r.how == "ah" then
      c.age:SetText(GREY .. ((r.age == 0 or r.age == nil) and "today" or (r.age .. "d ago")) .. "|r")
    else
      c.age:SetText("")
    end
    row:Show()
  end
  for i = #d.rows + 1, #bRows do bRows[i]:Hide(); bRows[i].data = nil end
  bContent:SetHeight(math.max(ROW_H, #d.rows * ROW_H))
  if #d.rows == 0 then
    p.empty:SetText(GREY .. (d.bankT and "Nothing recorded in the bank." or "No bank data yet.") .. "|r")
    p.empty:Show()
  else
    p.empty:Hide()
  end

  if not missingName then bNameTries = 0 end
  if missingName and not bNameRetry and bNameTries < 5 then
    bNameRetry = true
    bNameTries = bNameTries + 1
    C_Timer.After(1, function() bNameRetry = false; ns.RefreshUI() end)
  end
end

------------------------------------------------------------------------
-- "Crafting" tab (v0.7): profit per craft for your recipes at current prices
------------------------------------------------------------------------

local CCOLS = {
  {key = "name",   label = "Makes",       w = 170, j = "LEFT",  str = true},
  {key = "skill",  label = "Skill-up",    w = 70,  j = "LEFT",  str = true},
  {key = "yield",  label = "x",           w = 26,  j = "RIGHT"},
  {key = "cost",   label = "Mats",        w = 76,  j = "RIGHT"},
  {key = "sell",   label = "Sells (net)", w = 84,  j = "RIGHT"},
  {key = "profit", label = "Profit",      w = 76,  j = "RIGHT"},
  {key = "roi",    label = "%",           w = 50,  j = "RIGHT"},
  {key = "perHour", label = "Vendor/hr",  w = 66,  j = "RIGHT"},
  {key = "floor",  label = "Floor",       w = 64,  j = "RIGHT"},
  {key = "listed", label = "Listed",      w = 54,  j = "RIGHT"},
  {key = "goal",   label = "For fees",    w = 60,  j = "RIGHT"},
}
do
  local x = 0
  for _, col in ipairs(CCOLS) do col.x = x; x = x + col.w + COL_GAP end
end
local cRows, cHeaderBtns = {}, {}
local cScroll, cContent
local cNameRetry, cNameTries = false, 0
local DIFF_COLOR = {difficult = RED, optimal = ORANGE, medium = "|cffffff00", easy = GREEN, trivial = GREY}

local function CRowTooltip(row)
  local r = row.data
  if not r or not GameTooltip then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  if GameTooltip.SetItemByID then GameTooltip:SetItemByID(r.id) else GameTooltip:SetHyperlink("item:" .. r.id) end
  GameTooltip:AddLine(" ")
  if not r.learned then
    local where = r.src == "trainer" and ("Trainer" .. (r.trainCost and (": " .. M(r.trainCost)) or ""))
      or r.src == "gearquest" and "Recipe item or trainer (from GearQuest's data)"
      or r.src == "window" and "Shown in your profession window"
      or "Built-in guess"
    GameTooltip:AddLine("Not learned yet - " .. (r.prof or "?") .. (r.skill and (" " .. r.skill) or ""), 1, 0.6, 0.2)
    GameTooltip:AddLine(where, 0.8, 0.8, 0.8)
    if r.payback then GameTooltip:AddLine("Training pays for itself after " .. r.payback .. " crafts", 0.8, 0.8, 0.8) end
  end
  -- compact by default (one line per reagent, pay-at-most for the top-level ones);
  -- hold Shift for every detail line
  local detail = IsShiftKeyDown and IsShiftKeyDown()
  local SRC = {cheapest = "cheapest", ah = "buy on AH", craft = "craft what you can"}
  GameTooltip:AddDoubleLine("Reagents" .. (r.seed and " (built-in guess - open your Engineering window)" or ""),
    "mats: " .. (SRC[r.source or "cheapest"] or "cheapest"), 1, 0.82, 0, 0.7, 0.7, 0.7)
  if r.tools then
    GameTooltip:AddLine("Needs: " .. table.concat(r.tools, ", "), unpack(r.anvil and C.orange or {0.7, 0.7, 0.7}))
  end
  local HOW = {vendor = "vendor", ah = "AH", craft = "craft"}
  local function reagentLines(list, indent)
    for _, rg in ipairs(list) do
      local name = ItemNameLink(rg.id) or ("item " .. rg.id)
      if rg.each then
        local right = M(floor(rg.each * rg.n + 0.5)) .. "  (" .. M(floor(rg.each + 0.5)) .. " " .. (HOW[rg.how] or "?") .. ")"
        local col = rg.how == "craft" and C.green or {0.8, 0.8, 0.8}
        GameTooltip:AddDoubleLine(indent .. rg.n .. "x " .. name, right, 1, 1, 1, col[1], col[2], col[3])
        -- depth: buying a batch costs more than the cheapest few units
        if detail and rg.how == "ah" then
          local mp = ns.MarketPrice(rg.id)
          if mp and mp.min and rg.each > mp.min then
            GameTooltip:AddDoubleLine(indent .. "    avg of cheapest " .. ns.CraftBuyUnits(), "lowest " .. M(mp.min),
              0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
          end
        end
        -- break-even: the most one can cost (everything else at today's price)
        local function fmt(v) return (v and v > 0) and M(v) or "-" end
        if (detail or indent == "") and (rg.maxVendor or rg.maxSell) then
          local txt
          if rg.maxVendor and (r.sellBy == "vendor" or not rg.maxSell or rg.maxSell == rg.maxVendor) then
            txt = fmt(rg.maxVendor) .. " (vendoring)"
          elseif rg.maxVendor then
            txt = fmt(rg.maxVendor) .. " vendoring, " .. fmt(rg.maxSell) .. " AH"
          else
            txt = fmt(rg.maxSell) .. " (AH)"
          end
          local limit = rg.maxVendor or rg.maxSell
          local mc = (limit and rg.each <= limit) and {0.55, 0.75, 0.55} or {1, 0.4, 0.4}
          local per = (rg.units and rg.units ~= rg.n) and string.format(" (%.4g per craft)", rg.units) or ""
          GameTooltip:AddDoubleLine(indent .. "    pay at most" .. per, txt, 0.6, 0.6, 0.6, mc[1], mc[2], mc[3])
        end
        if rg.how == "craft" then
          if detail and rg.buyEach then
            GameTooltip:AddDoubleLine(indent .. "    buying it instead", M(rg.buyEach) .. " each ("
              .. (HOW[rg.buyHow] or "?") .. ")", 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
          end
          if rg.parts and #indent < 8 then reagentLines(rg.parts, indent .. "    ") end
        end
      else
        GameTooltip:AddDoubleLine(indent .. rg.n .. "x " .. name, "no price", 1, 1, 1, C.red[1], C.red[2], C.red[3])
      end
    end
  end
  reagentLines(r.reagents, "")
  if r.saved and r.saved > 0 then
    GameTooltip:AddDoubleLine("Crafting the green ones yourself saves", M(r.saved) .. " per craft", 0.8, 0.8, 0.8,
      C.green[1], C.green[2], C.green[3])
  elseif r.saved and r.saved < 0 then
    GameTooltip:AddDoubleLine("Crafting the green ones costs extra", M(-r.saved) .. " per craft", 0.8, 0.8, 0.8,
      1, 0.6, 0.2)
  end
  if r.costCheapest and r.costCheapest < r.cost then
    GameTooltip:AddDoubleLine("Cheapest mix of buying and crafting", M(r.costCheapest) .. " (" .. M(r.cost - r.costCheapest)
      .. " less)", 0.8, 0.8, 0.8, 1, 0.6, 0.2)
  end
  if not detail then
    GameTooltip:AddLine("Hold Shift for buy-vs-craft prices, batch prices and pay-at-most for every part.", 0.5, 0.5, 0.5)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine("AH lowest / median", (r.low and M(r.low) or "-") .. " / " .. (r.median and M(r.median) or "-"),
    1, 1, 1, 1, 1, 1)
  if r.skipped and r.ahEach then
    GameTooltip:AddDoubleLine("  using, past the " .. ns.CraftSkipUnits() .. " cheapest units", M(r.ahEach),
      0.7, 0.7, 0.7, 1, 1, 1)
  end
  if r.listed then GameTooltip:AddDoubleLine("Listed now", tostring(r.listed), 1, 1, 1, 1, 1, 1) end
  local variable = (r.yieldMin or r.yield) ~= (r.yieldMax or r.yield)
  if variable or r.seenN then
    GameTooltip:AddDoubleLine("Makes per craft", string.format("%d-%d, using avg %.2f", r.yieldMin or r.yield,
      r.yieldMax or r.yield, r.yield), 1, 1, 1, 1, 1, 1)
    if r.seenN then
      GameTooltip:AddDoubleLine("  your crafts", string.format("%.2f avg from %d (%d-%d)", r.seenAvg, r.seenN,
        r.seenMin or 0, r.seenMax or 0), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
    else
      GameTooltip:AddLine("  craft with the window open and Ledger learns the real average", 0.6, 0.6, 0.6)
    end
  end
  local per = r.yield ~= 1 and string.format(" for %.4g", r.yield) or ""
  if r.ahNet then
    GameTooltip:AddDoubleLine("AH, after 5% cut", M(r.ahNet) .. per, 1, 1, 1,
      unpack(r.sellBy == "ah" and {1, 1, 1} or {0.6, 0.6, 0.6}))
  end
  if r.vendorNet then
    GameTooltip:AddDoubleLine("Vendor pays", M(r.vendorNet) .. per .. "  (" .. M(r.vendorEach) .. " each)", 1, 1, 1,
      unpack(r.sellBy == "vendor" and {1, 1, 1} or {0.6, 0.6, 0.6}))
  end
  if r.profit then
    GameTooltip:AddDoubleLine("Profit per craft" .. (r.sellBy == "vendor" and " (vendor)" or " (AH)"), M(r.profit),
      1, 1, 1, unpack(r.profit >= 0 and C.green or C.red))
    if r.sellBy == "ah" and r.floor then
      GameTooltip:AddDoubleLine("Vendor floor (if it doesn't sell)", M(r.floor), 1, 1, 1,
        unpack(r.floor >= 0 and C.green or C.red))
    end
    if r.worst and variable then
      GameTooltip:AddDoubleLine("Unlucky craft (makes " .. (r.yieldMin or 1) .. ", vendored)", M(r.worst), 1, 1, 1,
        unpack(r.worst >= 0 and C.green or C.red))
    end
    if r.sellBy == "vendor" then
      GameTooltip:AddLine("A vendor pays more than the AH: sell it there, no cut and no waiting.", 0.7, 0.7, 0.7)
    end
    if r.worst and r.worst >= 0 then
      GameTooltip:AddLine("Can't lose money on any craft: whatever doesn't sell can go to a vendor.", 0.7, 0.7, 0.7)
    elseif r.floor and r.floor >= 0 then
      GameTooltip:AddLine("Profitable at a vendor on average; a single unlucky craft can lose.", 0.7, 0.7, 0.7)
    end
    if r.profit < 0 then GameTooltip:AddLine("Cheaper to buy on the AH than to craft.", 0.7, 0.7, 0.7) end
  end
  if r.secs then
    local t = string.format("%.1fs per craft", r.secs)
    if r.subCrafts and r.subCrafts > 0 then t = t .. string.format(" (incl. %.3g part crafts)", r.subCrafts) end
    GameTooltip:AddDoubleLine("Crafting time", t, 1, 1, 1, 1, 1, 1)
    if r.perHour then
      GameTooltip:AddDoubleLine("Per hour, vendoring everything", M(r.perHour), 1, 1, 1,
        unpack(r.perHour >= 0 and C.green or C.red))
    elseif not r.floor then
      GameTooltip:AddLine("Vendor/hr: no vendor price for this item.", 0.6, 0.6, 0.6)
    end
    GameTooltip:AddLine("Crafting time only: buying, posting and waiting for sales aren't counted.", 0.6, 0.6, 0.6)
  elseif r.untimed and r.floor then
    local names = {}
    for _, id in ipairs(r.untimed) do names[#names + 1] = ItemNameLink(id) or ("item " .. id) end
    GameTooltip:AddLine("Vendor/hr: not timed yet - craft " .. table.concat(names, ", ")
      .. " once with the profession window open.", 0.6, 0.6, 0.6, true)
  end
  if r.priceSrc then
    local label = r.priceSrc == "live" and "live AH search" or (r.priceSrc == "ahdb" and "AHDB scan" or "Auctionator")
    local col = r.priceSrc == "live" and C.green or {0.7, 0.7, 0.7}
    GameTooltip:AddLine("Price from " .. label .. (r.priceT and (", " .. Ago(r.priceT)) or ""), col[1], col[2], col[3])
  end
  if r.age and r.age > 0 then GameTooltip:AddLine("Price last seen " .. r.age .. "d ago", 1, 0.6, 0.2) end
  GameTooltip:AddLine("Listings aren't sales: check how fast it sells before making many.", 0.6, 0.6, 0.6)
  GameTooltip:AddLine("Alt-click: AuctionDB price graph.  Shift-click: link in chat", 0.6, 0.6, 0.6)
  GameTooltip:AddLine("Right-click: Auctionator shopping list for 1-100 crafts", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

-- Shift pressed/released over a crafting row: redraw its tooltip (compact <-> detail)
do
  local mod = CreateFrame("Frame")
  pcall(mod.RegisterEvent, mod, "MODIFIER_STATE_CHANGED")
  mod:SetScript("OnEvent", function()
    if not GameTooltip or not GameTooltip:IsShown() then return end
    local owner = GameTooltip:GetOwner()
    if owner and owner.isCraft and owner.data and owner:IsMouseOver() then CRowTooltip(owner) end
  end)
end

-- Right-click menu on a crafting row: shopping list for 1 to 100 crafts.
local SHOP_COUNTS = {1, 10, 20, 50, 100}
local craftMenu
local function ShowCraftMenu(row)
  local r = row.data
  if not r then return end
  if not craftMenu then
    craftMenu = CreateFrame("Frame", "LedgerCraftMenu", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    craftMenu:SetFrameStrata("FULLSCREEN_DIALOG")
    craftMenu:SetClampedToScreen(true)
    craftMenu:EnableMouse(true)
    if craftMenu.SetBackdrop then
      craftMenu:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = {left = 3, right = 3, top = 3, bottom = 3},
      })
      craftMenu:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
    else
      local bg = Tex(craftMenu, "BACKGROUND", {0.05, 0.05, 0.07}, 0.95)
      bg:SetAllPoints()
    end
    craftMenu.title = FS(craftMenu, "GameFontNormalSmall", "LEFT", 220)
    craftMenu.title:SetPoint("TOPLEFT", 8, -7)
    craftMenu.items = {}
    local keys = {}
    for _, n in ipairs(SHOP_COUNTS) do keys[#keys + 1] = n end
    keys[#keys + 1] = "cancel"
    for i, key in ipairs(keys) do
      local b = CreateFrame("Button", nil, craftMenu)
      b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
      b:SetSize(250, 16)
      b:SetPoint("TOPLEFT", 6, -6 - i * 16)
      b.text = FS(b, "GameFontHighlightSmall", "LEFT", 150)
      b.text:SetPoint("LEFT", 2, 0)
      b.cost = FS(b, "GameFontHighlightSmall", "RIGHT", 96)
      b.cost:SetPoint("RIGHT", -2, 0)
      local hl = Tex(b, "HIGHLIGHT", {1, 1, 1}, 0.15)
      hl:SetAllPoints()
      craftMenu.items[key] = b
    end
    for _, n in ipairs(SHOP_COUNTS) do craftMenu.items[n].text:SetText("Shopping list: " .. n .. "x") end
    craftMenu.items.cancel.text:SetText(GREY .. (CANCEL or "Cancel") .. "|r")
    craftMenu.items.cancel:SetScript("OnClick", function() craftMenu:Hide() end)
    craftMenu:SetSize(262, 6 + (#keys + 1) * 16 + 8)
    craftMenu.title:SetWidth(246)
    if frame then frame:HookScript("OnHide", function() craftMenu:Hide() end) end
    -- close on a click outside (checked a moment later, so the buttons still get their click)
    pcall(craftMenu.RegisterEvent, craftMenu, "GLOBAL_MOUSE_DOWN")
    craftMenu:SetScript("OnEvent", function(self)
      if not self:IsShown() then return end
      local function check() if self:IsShown() and not self:IsMouseOver() then self:Hide() end end
      if C_Timer and C_Timer.After then C_Timer.After(0.05, check) else check() end
    end)
    if UISpecialFrames then table.insert(UISpecialFrames, "LedgerCraftMenu") end
  end
  craftMenu.title:SetText(ItemNameLink(r.id) or r.name or ("item " .. r.id))
  -- total cost of each list (AH + vendor), crafted parts rounded up to whole crafts
  for _, n in ipairs(SHOP_COUNTS) do
    local b = craftMenu.items[n]
    local ok, list = pcall(ns.CraftShoppingList, r, n)
    if ok and list then
      b.cost:SetText((#list.unpriced > 0 and (ORANGE .. "?|r ") or "") .. M(list.cost))
    else
      b.cost:SetText(GREY .. "-|r")
    end
    b:SetScript("OnClick", function() craftMenu:Hide(); Safe(ns.ShopForCraft, r, n) end)
  end
  if GameTooltip then GameTooltip:Hide() end
  local x, y = GetCursorPosition()
  local sc = UIParent:GetEffectiveScale()
  craftMenu:ClearAllPoints()
  craftMenu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / sc, y / sc)
  craftMenu:Show()
end

local function MakeCRow(i)
  local row = CreateFrame("Button", nil, cContent)
  row:SetSize(CW - 20, ROW_H)
  row:SetPoint("TOPLEFT", cContent, "TOPLEFT", 0, -(i - 1) * ROW_H)
  row.stripe = Tex(row, "BACKGROUND", {1, 1, 1}, (i % 2 == 0) and 0.04 or 0)
  row.stripe:SetAllPoints()
  row.hl = Tex(row, "HIGHLIGHT", {1, 1, 1}, 0.10)
  row.hl:SetAllPoints()
  row.cells = {}
  for _, col in ipairs(CCOLS) do
    local fs = FS(row, "GameFontHighlightSmall", col.j, col.w)
    fs:SetPoint("LEFT", row, "LEFT", col.x, 0)
    row.cells[col.key] = fs
  end
  row.isCraft = true
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetScript("OnEnter", CRowTooltip)
  row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  row:SetScript("OnClick", function(self, button)
    local r = self.data
    if not r then return end
    if button == "RightButton" then ShowCraftMenu(self); return end
    if AltGraph(r.id) then return end
    local _, link = ItemNameLink(r.id)
    if link and IsModifiedClick and IsModifiedClick("CHATLINK") and ChatEdit_InsertLink then
      ChatEdit_InsertLink(link)
    end
  end)
  cRows[i] = row
  return row
end

local function OnCHeaderClick(self)
  local ui = ns.db.ui
  local key = self.col.key
  if ui.cSortKey == key then
    ui.cSortAsc = not ui.cSortAsc
  else
    ui.cSortKey = key
    ui.cSortAsc = self.col.str and true or false
  end
  ns.RefreshUI()
end

function ns.CreateCraftPane(parent)
  local p = CreateFrame("Frame", nil, parent)
  p:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -36)
  p:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -PAD, 8)
  parent.craftPane = p

  p.summary = FS(p, "GameFontHighlightSmall", "LEFT", CW - 622)
  p.summary:SetPoint("TOPLEFT", 0, 0)
  p.summary:SetHeight(26)
  if p.summary.SetWordWrap then p.summary:SetWordWrap(true) end
  if p.summary.SetJustifyV then p.summary:SetJustifyV("TOP") end

  local allBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  allBtn:SetSize(104, 20)
  allBtn:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, 0)
  allBtn:SetScript("OnClick", function()
    ns.db.ui.cAll = not ns.db.ui.cAll
    ns.RefreshUI()
  end)
  p.allBtn = allBtn

  local newBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  newBtn:SetSize(100, 20)
  newBtn:SetPoint("TOPRIGHT", allBtn, "TOPLEFT", -4, 0)
  newBtn:SetScript("OnClick", function()
    ns.db.ui.cNew = not ns.db.ui.cNew
    ns.RefreshUI()
  end)
  p.newBtn = newBtn

  -- live prices: search this tab's products and reagents at the open AH
  local liveBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  liveBtn:SetSize(112, 20)
  liveBtn:SetPoint("TOPRIGHT", newBtn, "TOPLEFT", -4, 0)
  liveBtn:SetScript("OnClick", function()
    if ns.LiveProgress and ns.LiveProgress() then ns.LiveStop(); return end
    if not ns.LiveRefresh then return end
    local ok, why = ns.LiveRefresh(ns.CraftRefreshIDs(p.rowsShown or {}), function() ns.RefreshUI() end)
    if not ok then ns.Print("live prices: " .. tostring(why)) end
    ns.RefreshUI()
  end)
  liveBtn:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Refresh from AH")
    GameTooltip:AddLine("Searches each product and reagent shown here at the open auction house,", 1, 1, 1)
    GameTooltip:AddLine("one at a time (about a second each), for up-to-the-minute prices.", 1, 1, 1)
    GameTooltip:AddLine("Searching only: nothing is bought. Waits while AHDB scans.", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  liveBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  p.liveBtn = liveBtn

  -- profession shown: yours first (see ns.CraftProfList) -> ... -> All
  local profBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  profBtn:SetSize(86, 20)
  profBtn:SetPoint("TOPRIGHT", liveBtn, "TOPLEFT", -4, 0)
  profBtn:SetScript("OnClick", function()
    local list = ns.CraftProfList()
    local cur, nextProf = ns.db.ui.cProf or list[1], list[1]
    if cur == "All" then nextProf = list[1]
    else
      nextProf = "All"
      for i, name in ipairs(list) do if name == cur then nextProf = list[i + 1] or "All" end end
    end
    ns.db.ui.cProf = nextProf
    ns.RefreshUI()
  end)
  profBtn:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Profession")
    GameTooltip:AddLine("Click to switch: " .. table.concat(ns.CraftProfList(), ", ") .. ", All.", 1, 1, 1)
    GameTooltip:AddLine("Open a profession's window once to record the recipes you know.", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  profBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  p.profBtn = profBtn

  -- reagent sourcing: cheapest -> buy on AH -> craft what you can
  local matsBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  matsBtn:SetSize(104, 20)
  matsBtn:SetPoint("TOPRIGHT", profBtn, "TOPLEFT", -4, 0)
  matsBtn:SetScript("OnClick", function()
    local nextMode = {cheapest = "ah", ah = "craft", craft = "cheapest"}
    local m = nextMode[ns.CraftSource()] or "cheapest"
    ns.db.settings.craftSource = (m ~= "cheapest") and m or nil
    ns.RefreshUI()
  end)
  matsBtn:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Reagents: where they come from")
    GameTooltip:AddLine("Cheapest: buy or craft each part, whichever costs less.", 1, 1, 1)
    GameTooltip:AddLine("Buy on AH: buy every reagent; craft only what can't be bought.", 1, 1, 1)
    GameTooltip:AddLine("Craft: craft every part you have the recipe for (a vendor still wins if cheaper).", 1, 1, 1)
    GameTooltip:AddLine("Mats, Profit and the tooltip all follow this. Click to switch.", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  matsBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  p.matsBtn = matsBtn

  -- no-anvil mode: hide recipes that need an anvil (crafting at the AH)
  local anvilBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  anvilBtn:SetSize(88, 20)
  anvilBtn:SetPoint("TOPRIGHT", matsBtn, "TOPLEFT", -4, 0)
  anvilBtn:SetScript("OnClick", function()
    ns.db.settings.craftNoAnvil = not ns.CraftNoAnvil() or nil
    ns.RefreshUI()
  end)
  anvilBtn:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Anvil")
    GameTooltip:AddLine("No anvil: hide recipes that need an anvil, and buy parts that need one", 1, 1, 1)
    GameTooltip:AddLine("instead of crafting them - for crafting where you stand, e.g. at the AH.", 1, 1, 1)
    GameTooltip:AddLine("Only recipes read from your profession window know their tools.", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  anvilBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  p.anvilBtn = anvilBtn

  p.header = CreateFrame("Frame", nil, p)
  p.header:SetSize(CW, ROW_H + 2)
  p.header:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -30)
  for _, col in ipairs(CCOLS) do
    local b = CreateFrame("Button", nil, p.header)
    b:SetSize(col.w, ROW_H)
    b:SetPoint("LEFT", p.header, "LEFT", col.x, 0)
    b.text = FS(b, "GameFontNormalSmall", col.j, col.w)
    b.text:SetAllPoints()
    b.col = col
    b:SetScript("OnClick", OnCHeaderClick)
    local hl = Tex(b, "HIGHLIGHT", {1, 1, 1}, 0.12)
    hl:SetAllPoints()
    cHeaderBtns[col.key] = b
  end
  local line = Tex(p.header, "ARTWORK", C.gold, 0.4)
  line:SetHeight(1)
  line:SetPoint("BOTTOMLEFT", 0, 0)
  line:SetPoint("BOTTOMRIGHT", 0, 0)

  local ok, sf = pcall(CreateFrame, "ScrollFrame", "LedgerCraftScrollFrame", p, "UIPanelScrollFrameTemplate")
  if not ok or not sf then
    sf = CreateFrame("ScrollFrame", "LedgerCraftScrollFrame", p)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
      local maxV = math.max(0, cContent:GetHeight() - self:GetHeight())
      self:SetVerticalScroll(math.min(maxV, math.max(0, self:GetVerticalScroll() - delta * ROW_H * 3)))
    end)
  end
  cScroll = sf
  cScroll:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -30 - ROW_H - 4)
  cScroll:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -22, 36)
  cContent = CreateFrame("Frame", nil, cScroll)
  cContent:SetSize(CW - 20, ROW_H)
  cScroll:SetScrollChild(cContent)

  p.empty = FS(cContent, "GameFontHighlightSmall", "LEFT", CW - 20)
  p.empty:SetPoint("TOPLEFT", 0, -2)

  p.footer = FS(p, "GameFontDisableSmall", "LEFT", CW)
  p.footer:SetPoint("BOTTOMLEFT", 0, 18)
  p.footer:SetText("Sells = AH (min(lowest, median) x yield, after 5% cut) or vendor (V) if it pays more, minus mats."
    .. " Floor = avg profit at a vendor: green can't lose, yellow on average.")
  p.footer2 = FS(p, "GameFontDisableSmall", "LEFT", CW)
  p.footer2:SetPoint("BOTTOMLEFT", 0, 4)
  p.footer2:SetText("Mats " .. GREEN .. "*|r = includes a reagent you craft (Mats button: cheapest / buy / craft).  For fees = crafts to cover loan"
    .. " fees.  Visit your trainer to add recipes you can learn.  Hover for reagents.")
  p:Hide()
end

local function RefreshCraft()
  local p = frame.craftPane
  if not p then return end
  local db = ns.db
  local showAll = db.ui.cAll and true or false
  local showNew = db.ui.cNew and true or false
  p.allBtn:SetText(showAll and "All recipes" or "Profitable only")
  p.newBtn:SetText(showNew and "+ Not learned" or "Learned only")
  local profShown = db.ui.cProf or ns.MainCraftProf()
  p.profBtn:SetText(profShown)
  p.matsBtn:SetText(({cheapest = "Mats: cheapest", ah = "Mats: buy AH", craft = "Mats: craft"})[ns.CraftSource()])
  local noAnvil = ns.CraftNoAnvil()
  p.anvilBtn:SetText(noAnvil and "No anvil" or "Anvil: any")
  local all = ns.CraftMargins()
  if profShown ~= "All" then
    local keep = {}
    for _, r in ipairs(all) do if r.prof == profShown then keep[#keep + 1] = r end end
    all = keep
  end
  local goal = ns.LoanFeesOpen and ns.LoanFeesOpen() or 0

  local seed, nProfit, best, nNew = false, 0, nil, 0
  for _, r in ipairs(all) do
    if r.seed and r.learned then seed = true end
    if r.profit and r.profit > 0 then
      if r.learned then
        nProfit = nProfit + 1
        if not best or r.profit > best.profit then best = r end
      else
        nNew = nNew + 1
      end
    end
  end

  local parts = {}
  if seed then
    table.insert(parts, ORANGE .. "Built-in Engineering recipes (unverified) - open your Engineering window|r")
  elseif profShown ~= "All" and not (db.recipeProfs or {})[profShown] then
    table.insert(parts, ORANGE .. profShown .. ": open its window to record your recipes|r")
  else
    local profs = {}
    for name, info in pairs(db.recipeProfs or {}) do
      if name ~= "" and (profShown == "All" or name == profShown) then
        profs[#profs + 1] = name .. (info.rank and (" " .. info.rank) or "")
      end
    end
    table.sort(profs)
    table.insert(parts, table.concat(profs, ", "))
  end
  table.insert(parts, (nProfit > 0 and GREEN or "") .. nProfit .. " profitable|r")
  if nNew > 0 then table.insert(parts, GREY .. "+" .. nNew .. " not learned|r") end
  if best then
    table.insert(parts, "best " .. (ItemNameLink(best.id) or best.name or ("item " .. best.id)) .. " " .. GREEN .. "+"
      .. M(best.profit) .. "|r")
  end
  if goal > 0 then table.insert(parts, ORANGE .. "loan fees to earn " .. M(goal) .. "|r") end
  if noAnvil then
    -- learned recipes whose tools haven't been read: reopen the window once
    local unread = 0
    for _, r in ipairs(all) do if r.learned and not r.toolsRead and not r.seed then unread = unread + 1 end end
    table.insert(parts, unread > 0
      and (ORANGE .. "no anvil: " .. unread .. " unchecked - reopen the profession window|r")
      or (GREY .. "no anvil|r"))
  end
  if not (Auctionator and Auctionator.API) and not ns.HasAHDB() then
    table.insert(parts, RED .. "no AHDB or Auctionator - no prices|r")
  end
  -- live prices
  local done, total = nil, nil
  if ns.LiveProgress then done, total = ns.LiveProgress() end
  if done then
    table.insert(parts, ORANGE .. "searching AH " .. done .. "/" .. total .. "|r")
    p.liveBtn:SetText("Stop (" .. done .. "/" .. total .. ")")
    p.liveBtn:Enable()
  else
    p.liveBtn:SetText("Refresh from AH")
    if ns.AHOpen and ns.AHOpen() then p.liveBtn:Enable() else p.liveBtn:Disable() end
    local n, newest = 0, nil
    if ns.LiveSummary then n, newest = ns.LiveSummary() end
    if n > 0 then table.insert(parts, GREEN .. n .. " live|r" .. GREY .. " (" .. Ago(newest) .. ")|r") end
  end
  p.summary:SetText(table.concat(parts, "  |  "))

  local rows, missingName = {}, false
  for _, r in ipairs(all) do
    if (r.learned or showNew) and (showAll or (r.profit and r.profit > 0)) then
      local name = ItemNameLink(r.id)
      if not name then missingName = true end
      r.name = name or r.name or ("item " .. r.id)
      r.goal = goal > 0 and ns.CraftsFor(r, goal) or nil
      rows[#rows + 1] = r
    end
  end
  p.rowsShown = rows
  local ui = db.ui
  local key = ui.cSortKey or "profit"
  local asc = ui.cSortAsc and true or false
  table.sort(rows, function(a, b)
    local va, vb = a[key], b[key]
    if key == "skill" then va, vb = a.skill or 0, b.skill or 0 end
    if type(va) == "string" or type(vb) == "string" then va, vb = lower(tostring(va or "")), lower(tostring(vb or "")) end
    if va == nil and vb == nil then return a.id < b.id end
    if va == nil then return false end
    if vb == nil then return true end
    if va == vb then return a.id < b.id end
    if asc then return va < vb end
    return va > vb
  end)
  for k, b in pairs(cHeaderBtns) do
    b.text:SetText(b.col.label .. ((k == key) and (asc and " ^" or " v") or ""))
  end

  for i, r in ipairs(rows) do
    local row = cRows[i] or MakeCRow(i)
    row.data = r
    local c = row.cells
    c.name:SetText((r.learned and "" or GREY) .. r.name .. (r.learned and "" or "|r")
      .. (r.missing > 0 and (RED .. " ?|r") or ""))
    if not r.learned then
      -- green: you have the skill to learn it now; red: not yet
      local col = r.canLearn == true and GREEN or (r.canLearn == false and RED or GREY)
      c.skill:SetText(col .. "learn" .. (r.skill and (" " .. r.skill) or "") .. "|r")
    elseif r.difficulty then
      c.skill:SetText((DIFF_COLOR[r.difficulty] or "") .. r.difficulty .. "|r")
    else
      c.skill:SetText(GREY .. (r.skill and ("needs " .. r.skill) or "-") .. "|r")
    end
    if (r.yieldMin or r.yield) ~= (r.yieldMax or r.yield) then
      c.yield:SetText((r.seenN and "" or GREY) .. string.format("%.1f", r.yield) .. (r.seenN and "" or "|r"))
    else
      c.yield:SetText(r.yield ~= 1 and tostring(r.yield) or "")
    end
    -- green * = cheaper by crafting one of its reagents yourself (see tooltip)
    c.cost:SetText(r.missing > 0 and (RED .. "?|r") or (M(r.cost) .. (r.crafted and (GREEN .. "*|r") or "")))
    c.sell:SetText(r.sell and (M(r.sell) .. (r.sellBy == "vendor" and (GOLD .. " V|r") or "")) or (GREY .. "no price|r"))
    -- floor = profit if sold to a vendor; green means the craft can't lose money
    if r.floor then
      -- green: no single craft can lose; yellow: profitable on average only
      local col = (r.worst and r.worst >= 0) and GREEN or (r.floor >= 0 and "|cffffff00" or GREY)
      c.floor:SetText(col .. M(r.floor) .. "|r")
    else
      c.floor:SetText(GREY .. "-|r")
    end
    if r.profit then
      c.profit:SetText((r.profit >= 0 and GREEN or RED) .. M(r.profit) .. "|r")
      c.roi:SetText(r.roi and ((r.profit >= 0 and GREEN or RED) .. Pct(r.roi, true) .. "|r") or "")
    else
      c.profit:SetText(GREY .. "-|r"); c.roi:SetText("")
    end
    -- profit per hour selling everything to a vendor; blank until every craft involved has been timed
    c.perHour:SetText(r.perHour and ((r.perHour >= 0 and GREEN or RED) .. M(r.perHour) .. "|r") or "")
    c.listed:SetText(r.listed and tostring(r.listed) or (GREY .. "-|r"))
    c.goal:SetText(r.goal and tostring(r.goal) or "")
    row:Show()
  end
  for i = #rows + 1, #cRows do cRows[i]:Hide(); cRows[i].data = nil end
  cContent:SetHeight(math.max(ROW_H, #rows * ROW_H))
  if #rows == 0 then
    p.empty:SetText(GREY .. (#all == 0 and "No recipes yet - open a profession window."
      or "Nothing is profitable at current prices. Click Profitable only to see all recipes.") .. "|r")
    p.empty:Show()
  else
    p.empty:Hide()
  end

  if not missingName then cNameTries = 0 end
  if missingName and not cNameRetry and cNameTries < 5 then
    cNameRetry = true
    cNameTries = cNameTries + 1
    C_Timer.After(1, function() cNameRetry = false; ns.RefreshUI() end)
  end
end

------------------------------------------------------------------------
-- refresh
------------------------------------------------------------------------

local function Takeaway(d)
  local parts = {}
  if d.unrealPct then
    table.insert(parts, "Unrealized " .. GainColor(d.unreal) .. Pct(d.unrealPct, true) .. "|r after cut")
  else
    table.insert(parts, GREY .. "No prices yet|r")
  end
  if d.largestCat and d.totalValue > 0 then
    table.insert(parts, string.format("largest category %s %s", d.largestCat.name,
      (d.largestCat.over and ORANGE or "") .. Pct(d.largestCat.share) .. "|r"))
  end
  if d.largestItem then
    table.insert(parts, string.format("largest item %s %s", d.largestItem.name,
      (d.largestItem.cap and ORANGE or "") .. Pct(d.largestItem.share) .. "|r"))
  end
  if d.overCap > 0 then
    table.insert(parts, ORANGE .. d.overCap .. " over the " .. Pct(d.cap) .. " cap|r")
  else
    table.insert(parts, GREEN .. "nothing over the " .. Pct(d.cap) .. " cap|r")
  end
  table.insert(parts, "cash " .. (d.cashOk and (GREEN .. "above") or (RED .. "below")) .. "|r the "
    .. Pct(d.cashTarget) .. " target")
  if d.loans and #d.loans > 0 then
    local l = d.loans[1] -- soonest due
    local overdue = l.due and l.due < time()
    table.insert(parts, (overdue and RED or ORANGE) .. "owe " .. l.who .. " " .. M(ns.LoanOwed(l)) .. ", "
      .. ns.DueText(l) .. (#d.loans > 1 and (" (+" .. (#d.loans - 1) .. " more)") or "") .. "|r")
  end
  local nSell = 0
  for _, r in ipairs(d.rows) do if r.sell then nSell = nSell + 1 end end
  if nSell > 0 then table.insert(parts, GREEN .. nSell .. " sell signal" .. (nSell > 1 and "s" or "") .. "|r") end
  return table.concat(parts, "  |  ")
end

function ns.RefreshUI()
  if not frame or not frame:IsShown() or not ns.db then return end
  local tab = CurrentTab()
  ApplyTab(tab)
  if tab == "vendor" or tab == "bank" or tab == "craft" then
    -- the price freshness line stays useful on these tabs too
    local pt
    for _, l in pairs(ns.db.latest or {}) do
      if l.t and (not pt or l.t > pt) then pt = l.t end
    end
    frame.fresh:SetText(pt and (GREY .. "Prices from " .. date("%m-%d %H:%M", pt) .. " (" .. Ago(pt) .. ")|r") or "")
    if tab == "bank" then RefreshBank() elseif tab == "craft" then RefreshCraft() else RefreshVendor() end
    return
  end
  local d = ns.Compute()
  lastData = d

  -- freshness
  if d.priceTime then
    local stale = (time() - d.priceTime) > STALE_SECONDS
    frame.fresh:SetText((stale and ORANGE or GREY) .. "Prices from " .. date("%m-%d %H:%M", d.priceTime)
      .. " (" .. Ago(d.priceTime) .. ")" .. (stale and " - rescan!" or "") .. "|r")
  elseif not (Auctionator and Auctionator.API) and not ns.HasAHDB() then
    frame.fresh:SetText(RED .. "no AHDB or Auctionator - no prices|r")
  else
    frame.fresh:SetText(ORANGE .. "No prices yet - run an AHDB or Auctionator scan|r")
  end

  frame.takeaway:SetText(Takeaway(d))

  -- tiles
  tiles[1].value:SetText(M(d.wealth))
  tiles[1].sub:SetText(GREY .. (d.debt > 0 and "holdings + cash - loans" or "holdings + cash") .. "|r")
  tiles[2].value:SetText((d.cash < 0 and RED or "") .. M(d.cash) .. (d.cash < 0 and "|r" or ""))
  if d.debt > 0 then
    tiles[2].sub:SetText((d.cashOk and GREEN or RED) .. Pct(d.cashShare) .. "|r" .. ORANGE .. " owe "
      .. M(d.debt) .. "|r")
  else
    tiles[2].sub:SetText((d.cashOk and GREEN or RED) .. Pct(d.cashShare) .. "|r" .. GREY .. " / target " .. Pct(d.cashTarget) .. "|r")
  end
  tiles[3].value:SetText(M(d.totalValue))
  tiles[3].sub:SetText(GREY .. "at latest prices|r")
  tiles[4].value:SetText(M(d.totalCost))
  tiles[4].sub:SetText(GREY .. "average cost|r")
  tiles[5].value:SetText(GainColor(d.unreal) .. M(d.unreal) .. "|r")
  tiles[5].sub:SetText(GainColor(d.unreal) .. Pct(d.unrealPct, true) .. "|r")
  tiles[6].value:SetText(GainColor(d.realized) .. M(d.realized) .. "|r")
  if (d.loanFees or 0) > 0 then
    tiles[6].sub:SetText(GREY .. "fees |r" .. RED .. "-" .. M(d.loanFees) .. "|r")
  else
    tiles[6].sub:SetText(GREY .. "to date|r")
  end
  tiles[7].value:SetText(tostring(d.nPositions))
  tiles[7].sub:SetText(GREY .. d.nCats .. " categories|r")

  -- allocation bars
  local y = -56 - TILE_H - 10
  frame.allocTitle:ClearAllPoints()
  frame.allocTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
  y = y - 16
  local shownCats = math.min(#d.cats, MAX_CATS)
  for i = 1, shownCats do
    local c = d.cats[i]
    local r = catRows[i] or MakeCatRow(i)
    PlaceCatRow(r, y)
    ShowCatRow(r, true)
    r.name:SetText(c.name)
    local w = math.max(1, CAT_BAR_W * math.min(1, c.share))
    r.fill:SetSize(w, CAT_ROW_H - 4)
    SetTexColor(r.fill, c.over and C.red or C.bar, 0.9)
    if c.value <= 0 then r.fill:Hide() end
    r.capLine:ClearAllPoints()
    r.capLine:SetPoint("TOPLEFT", r.bg, "TOPLEFT", CAT_BAR_W * math.min(1, d.cap), 1)
    r.label:SetText((c.over and RED or "") .. Pct(c.share) .. "|r  " .. M(c.value)
      .. GREY .. "  (" .. c.n .. (c.n == 1 and " item" or " items") .. ")|r")
    y = y - CAT_ROW_H
  end
  for i = shownCats + 1, #catRows do ShowCatRow(catRows[i], false) end
  frame.allocNote:ClearAllPoints()
  frame.allocNote:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + CAT_NAME_W, y - 1)
  frame.allocNote:SetText("Orange line = " .. Pct(d.cap) .. " cap. Red bar = over the cap."
    .. (#d.cats > MAX_CATS and ("  (" .. (#d.cats - MAX_CATS) .. " more not shown)") or ""))
  y = y - 18

  -- table header
  frame.header:ClearAllPoints()
  frame.header:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
  local ui = ns.db.ui
  local sortKey = ui.sortKey or "value"
  for key, b in pairs(headerBtns) do
    local arrow = ""
    if key == sortKey then arrow = ui.sortAsc and " ^" or " v" end
    b.text:SetText(b.col.label .. arrow)
  end
  y = y - ROW_H - 4

  -- table body
  scroll:ClearAllPoints()
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD - 22, 44)
  local rows = d.rows
  SortRows(rows)
  local maxAbs = 0
  for _, r in ipairs(rows) do
    if r.pct and math.abs(r.pct) > maxAbs then maxAbs = math.abs(r.pct) end
  end
  for i, r in ipairs(rows) do
    FillRow(rowPool[i] or MakeRow(i), r, maxAbs)
  end
  for i = #rows + 1, #rowPool do rowPool[i]:Hide(); rowPool[i].data = nil end
  content:SetHeight(math.max(ROW_H, #rows * ROW_H))
  if #rows == 0 then
    local r = rowPool[1] or MakeRow(1)
    for _, fs in pairs(r.cells) do fs:SetText("") end
    r.cells.name:SetText(GREY .. "No open positions|r")
    r.bar:Hide(); for _, t in ipairs(r.spark) do t:Hide() end
    r.data = nil
    r:Show()
  end

  -- footer
  frame.footer:SetText(string.format(
    "Targets: cash >= %s   cap %s per item/category   sell signal at +%s after the %d%% AH cut   |   Realized %s%s",
    Pct(d.cashTarget), Pct(d.cap), Pct(d.sellGain), ns.AH_CUT * 100, M(d.realized),
    (function()
      -- crafting spending per reason (Engineering, Blacksmithing, ...)
      local t = {}
      for reason, v in pairs(d.used or {}) do
        if v > 0 then t[#t + 1] = "Used for " .. reason .. " " .. M(v) end
      end
      table.sort(t)
      return #t > 0 and ("   |   " .. table.concat(t, ", ")) or ""
    end)())
    .. (d.debt > 0 and ("   |   " .. ORANGE .. "Loans owed " .. M(d.debt) .. "|r") or ""))
  local nExcl = 0
  for _ in pairs(ns.db.excluded or {}) do nExcl = nExcl + 1 end
  frame.footer2:SetText("* Unrealized is after the 5% AH cut, for priced items only.  "
    .. "Click a header to sort; hover a row for details; right-click to mark used or exclude."
    .. (nExcl > 0 and (ORANGE .. "  " .. nExcl .. " excluded (/ledger excluded)|r") or "")
    .. "  /ledger help")
end

function ns.ToggleUI()
  if not ns.db then return end
  if not frame then CreateUI() end
  if frame:IsShown() then
    frame:Hide()
  else
    ns.CountHoldings()
    frame:Show() -- OnShow refreshes
  end
end

------------------------------------------------------------------------
-- minimap button (simple, draggable around the minimap)
------------------------------------------------------------------------

local mmButton

local function PlaceMinimapButton()
  if not mmButton or not Minimap then return end
  local angle = math.rad(ns.db.ui.minimapAngle or 210)
  local radius = (Minimap:GetWidth() or 140) / 2 + 8
  mmButton:ClearAllPoints()
  mmButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function CreateMinimapButton()
  if mmButton or not Minimap then return end
  local b = CreateFrame("Button", "LedgerMinimapButton", Minimap)
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local icon = b:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture("Interface\\Icons\\INV_Misc_Book_11")
  icon:SetSize(20, 20)
  icon:SetPoint("TOPLEFT", 6, -5)
  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  b:SetScript("OnClick", function() ns.ToggleUI() end)
  b:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local s = Minimap:GetEffectiveScale()
      if not (mx and cx and s and s > 0) then return end
      local atan2 = math.atan2 or atan2
      ns.db.ui.minimapAngle = math.deg(atan2(cy / s - my, cx / s - mx))
      PlaceMinimapButton()
    end)
  end)
  b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  b:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Ledger")
    GameTooltip:AddLine("Click: show/hide portfolio. Drag: move.", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  mmButton = b
end

function ns.UpdateMinimapButton()
  if not ns.db then return end
  if ns.db.ui.minimapHidden then
    if mmButton then mmButton:Hide() end
    return
  end
  CreateMinimapButton()
  if mmButton then
    PlaceMinimapButton()
    mmButton:Show()
  end
end
