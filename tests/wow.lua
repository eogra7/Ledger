-- Minimal WoW API stand-ins so Ledger's Core.lua, Live.lua and Craft.lua can load
-- outside the game. UI.lua isn't loaded (it's all frames); CI syntax-checks it.
-- Everything here is made-up test data: never load real SavedVariables.
local W = {}

unpack = unpack or table.unpack
time = time or os.time
date = date or os.date

W.ADDON = (os.getenv("LEDGER_DIR") or ".") .. "/"
W.NOW = 1800000000 -- fixed "server time" for the tests

-- item data: [id] = {name, vendorSellPrice}
W.ITEMS = {
  [2841] = {"Bronze Bar", 0},
  [4306] = {"Silk Cloth", 0},
  [4371] = {"Bronze Tube", 0},
  [4380] = {"Big Bronze Bomb", 800},
  [2851] = {"Copper Chain Belt", 0},
  [2840] = {"Copper Bar", 0},
  [3575] = {"Iron Bar", 0},
}

-- AHDB-style price fixture: [id] = min buyout (also used as median), copper
W.PRICES = {[2841] = 100, [4306] = 50, [4371] = 500, [4380] = 1000, [2840] = 30, [2851] = 900}

-- Resets every global the addon touches and loads it fresh.
-- opts.db = LedgerDB to start with (nil = new install)
-- opts.recipes = classic trade skill window to show: {prof, rank, {product, name, yield, {{id, n}...}, tools...}}
function W.load(opts)
  opts = opts or {}
  W.frames, W.timers, W.chat = {}, {}, {}
  W.clock = W.NOW
  time = function() return W.clock end
  function CreateFrame()
    local f = {ev = {}}
    f.RegisterEvent = function(s, e) s.ev[e] = true end
    f.UnregisterEvent = function(s, e) s.ev[e] = nil end
    f.SetScript = function(s, _, fn) s.fn = fn end
    W.frames[#W.frames + 1] = f
    return f
  end
  C_Timer = {After = function(_, fn) W.timers[#W.timers + 1] = fn end}
  DEFAULT_CHAT_FRAME = {AddMessage = function(_, m)
    W.chat[#W.chat + 1] = (m:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
  end}
  function UnitFactionGroup() return "Alliance" end
  function GetTime() return W.clock end
  function GetItemInfo(id)
    local it = W.ITEMS[id]
    if not it then return nil end
    return it[1], "item:" .. id, nil, nil, nil, nil, nil, nil, nil, nil, it[2]
  end
  function GetItemCount() return 0 end
  SlashCmdList = {}
  Auctionator, GearQuest, AuctionDB = nil, opts.gearquest, nil
  -- opts.client = {GetItemInfo = fn|false, C_Item = table}: stand in for other game clients
  local client = opts.client or {}
  if client.GetItemInfo ~= nil then GetItemInfo = client.GetItemInfo or nil end
  C_Item = client.C_Item
  local items = {}
  for id, p in pairs(W.PRICES) do items[id] = string.format("%d,%d,%d,%d", W.NOW - 60, p, p, 20) end
  AuctionDBForeverSaved = {houses = {Alliance = {items = items, daily = {}, scans = {{W.NOW - 60, 100, 10}}}}}
  W.setWindow(opts.recipes)
  LedgerDB = opts.db
  local ns = {}
  for _, f in ipairs({"Core.lua", "Live.lua", "Craft.lua"}) do
    local chunk = assert(loadfile(W.ADDON .. f))
    chunk("Ledger", ns)
  end
  W.fire("ADDON_LOADED", "Ledger")
  return ns
end

function W.fire(event, ...)
  for _, f in ipairs(W.frames) do
    if f.ev[event] and f.fn then f.fn(f, event, ...) end
  end
end

function W.runTimers()
  for _ = 1, 5 do
    local t = W.timers
    W.timers = {}
    for _, fn in ipairs(t) do fn() end
  end
end

-- Classic profession window API (GetTradeSkillInfo & co.) showing `win`.
function W.setWindow(win)
  if not win then
    GetNumTradeSkills = nil
    return
  end
  local list = win[3]
  GetNumTradeSkills = function() return #list end
  GetTradeSkillLine = function() return win[1], win[2] end
  GetTradeSkillInfo = function(i) return list[i][2], "optimal" end
  GetTradeSkillItemLink = function(i) return "|Hitem:" .. list[i][1] .. ":|h" end
  GetTradeSkillNumMade = function(i) return list[i][3], list[i][3] end
  GetTradeSkillNumReagents = function(i) return #list[i][4] end
  GetTradeSkillReagentInfo = function(i, j) return "x", nil, list[i][4][j][2] end
  GetTradeSkillReagentItemLink = function(i, j) return "|Hitem:" .. list[i][4][j][1] .. ":|h" end
  GetTradeSkillTools = function(i)
    local out = {}
    for _, t in ipairs(list[i][5] or {}) do out[#out + 1] = t; out[#out + 1] = true end
    return unpack(out)
  end
end

-- The Engineering window used by most craft tests:
--   Bronze Tube     = 2 Bronze Bar (needs an anvil)
--   Big Bronze Bomb = 1 Bronze Tube + 3 Silk Cloth
W.ENGINEERING = {"Engineering", 150, {
  {4371, "Bronze Tube", 1, {{2841, 2}}, {"Anvil", "Blacksmith Hammer"}},
  {4380, "Big Bronze Bomb", 1, {{4371, 1}, {4306, 3}}},
}}

function W.row(ns, id)
  for _, r in ipairs(ns.CraftMargins()) do if r.id == id then return r end end
  return nil
end

return W
