-- Ledger: crafting margin check (v0.7). Read-only: it never crafts, buys or posts.
--
-- Recipes come from your own profession window: each time it opens (or its list
-- changes) Ledger records every recipe you know, with reagents and how many it
-- makes, into LedgerDB.recipes. Until a profession window has been opened, a
-- small built-in Engineering list (SEED_RECIPES, from memory of Classic data,
-- marked unverified) is used instead.
--
-- Margin per craft = product price x yield x (1 - AH cut) - reagent cost, where
--   product price = min(lowest buyout, median) from the latest scan (AHDB, or
--                   Auctionator's price when AHDB has none)
--   reagent cost  = lowest buyout, or the vendor price for trade-supply items
--                   (VENDOR_BUY), whichever is cheaper

local _, ns = ...
local floor, min, max = math.floor, math.min, math.max
local Print = ns.Print

-- Trade-supply reagents sold by vendors (copper each). Approximate; used when
-- cheaper than (or missing from) the AH.
local VENDOR_BUY = {
  [2880] = 100,   -- Weak Flux
  [3466] = 200,   -- Strong Flux
  [4399] = 200,   -- Wooden Stock
  [4400] = 1000,  -- Heavy Stock
  [2320] = 10,    -- Coarse Thread
  [2321] = 100,   -- Fine Thread
  [4291] = 500,   -- Silken Thread
  [8343] = 2000,  -- Heavy Silken Thread
  [14341] = 5000, -- Rune Thread
  [4289] = 50,    -- Salt
  [3371] = 4,     -- Empty Vial
  [3372] = 40,    -- Leaded Vial
  [2324] = 25,    -- Bleach
  [2604] = 50,    -- Red Dye
}
ns.VENDOR_BUY = VENDOR_BUY

-- What a vendor charges for one (copper), or nil: prices read from merchants
-- you've opened (LedgerDB.vendorBuy, v0.8.5) win over the built-in list above.
function ns.VendorBuyPrice(itemID)
  local l = ns.db and ns.db.vendorBuy and ns.db.vendorBuy[itemID]
  if l and l.price then return l.price, l.merchant end
  return VENDOR_BUY[itemID]
end

-- Merchant window: record every item sold for gold, in unlimited stock, at the
-- price you actually pay (reputation discounts included), per unit:
--   LedgerDB.vendorBuy[itemID] = {price, merchant, t}
-- Read-only: Ledger only reads the merchant's list, it never buys.
local function ReadMerchant()
  local db = ns.db
  if not db then return 0 end
  local n = (GetMerchantNumItems and GetMerchantNumItems()) or 0
  if n == 0 then return 0 end
  db.vendorBuy = db.vendorBuy or {}
  local who = UnitName and UnitName("npc") or nil
  local added = 0
  for i = 1, n do
    local id = GetMerchantItemID and GetMerchantItemID(i)
    local price, qty, avail, extended
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
      local ok, info = pcall(C_MerchantFrame.GetItemInfo, i)
      if ok and type(info) == "table" then
        price, qty, avail, extended = info.price, info.stackCount, info.numAvailable, info.hasExtendedCost
      end
    end
    if price == nil and GetMerchantItemInfo then
      local ok, _, _, p, q, a, _, _, ext = pcall(GetMerchantItemInfo, i)
      if ok then price, qty, avail, extended = p, q, a, ext end
    end
    -- gold only (no tokens), unlimited stock (-1), known item
    if id and price and price > 0 and not extended and (avail == nil or avail < 0) then
      local each = floor(price / math.max(qty or 1, 1) + 0.5)
      local old = db.vendorBuy[id]
      if not old or old.price ~= each then added = added + 1 end
      db.vendorBuy[id] = {price = each, merchant = who, t = time()}
    end
  end
  return added
end

local mf = CreateFrame("Frame")
pcall(mf.RegisterEvent, mf, "MERCHANT_SHOW")
pcall(mf.RegisterEvent, mf, "MERCHANT_UPDATE")
mf:SetScript("OnEvent", function()
  if not ns.db then return end
  C_Timer.After(0.5, function()
    local added = ReadMerchant()
    if added > 0 then
      -- say so only when it matters: one of your recipes uses something this vendor sells
      local used = {}
      for _, r in pairs(ns.db.recipes or {}) do
        for _, rg in ipairs(r.reagents or {}) do
          local v = ns.db.vendorBuy[rg[1]]
          if v and v.t and time() - v.t < 5 then used[rg[1]] = v.price end
        end
      end
      local names = {}
      for id, price in pairs(used) do
        names[#names + 1] = (ns.ItemName(id) or ("item " .. id)) .. " " .. ns.Money(price)
      end
      if #names > 0 then
        table.sort(names)
        Print("vendor sells reagents you use: " .. table.concat(names, ", ") .. " (crafting prices updated).")
      end
      if ns.RefreshUI then ns.RefreshUI() end
    end
  end)
end)

-- {product, name, yield, skill, {{reagent, n}, ...}}. Unverified: replaced by
-- your real recipes as soon as you open the Engineering window.
-- Observed yields count as much as this many crafts at the recipe's average
-- (so one lucky craft of 4 from a 1-5 recipe moves 3.0 to about 3.17).
local YIELD_PRIOR = 5

local SEED_RECIPES = {
  {4357, "Rough Blasting Powder",   1,   1, {{2835, 1}}},
  {4359, "Handful of Copper Bolts", 1,  30, {{2840, 1}}},
  {4361, "Copper Tube",             1,  50, {{2840, 2}, {2880, 1}}},
  {4364, "Coarse Blasting Powder",  1,  75, {{2836, 1}}},
  {4404, "Silver Contact",          5,  90, {{2842, 1}}},
  {4368, "Flying Tiger Goggles",    1, 100, {{2318, 6}, {818, 2}}},
  {6712, "Practice Lock",           1, 100, {{2841, 1}, {4359, 1}, {2880, 1}}},
  {4370, "Large Copper Bomb",       1, 105, {{2840, 3}, {4357, 4}, {4359, 1}}},
  {4371, "Bronze Tube",             1, 105, {{2841, 2}, {2880, 1}}},
  {4406, "Standard Scope",          1, 110, {{4371, 1}, {1206, 1}}},
  {4373, "Shadow Goggles",          1, 120, {{2319, 4}, {1210, 2}}},
  {4374, "Small Bronze Bomb",       2, 120, {{4364, 4}, {2841, 1}, {4306, 1}}},
  {4375, "Whirring Bronze Gizmo",   1, 125, {{2841, 2}, {2592, 1}}},
  {4378, "Heavy Dynamite",          2, 125, {{4364, 2}, {2592, 1}}},
}

------------------------------------------------------------------------
-- Recipe capture from the profession window
------------------------------------------------------------------------

local function IDFromLink(link)
  local id = type(link) == "string" and link:match("item:(%d+)")
  return id and tonumber(id) or nil
end

-- pcall wrapper that keeps every return value, nils included (a table +
-- unpack would cut the list at the first nil, e.g. a missing reagent texture)
local function Pass(ok, ...)
  if ok then return ... end
  return nil
end
local function Call(f, ...)
  if type(f) ~= "function" then return nil end
  return Pass(pcall(f, ...))
end

-- relativeDifficulty (modern) / skill type (classic) -> our label
local DIFF = {[0] = "optimal", [1] = "medium", [2] = "easy", [3] = "trivial",
  optimal = "optimal", medium = "medium", easy = "easy", trivial = "trivial", difficult = "difficult"}

-- Tools / stations a recipe needs (v0.8.14): names as the window shows them,
-- e.g. "Anvil", "Blacksmith Hammer". Sets r.tools, r.anvil and r.toolsRead.
local function SetTools(r, names)
  r.toolsRead = true
  if #names > 0 then r.tools = names end
  for _, t in ipairs(names) do
    if tostring(t):lower():find("anvil", 1, true) then r.anvil = true end
  end
end

-- Modern API (C_TradeSkillUI with recipe schematics).
local function ReadModern()
  local T = C_TradeSkillUI
  if not (T and T.GetAllRecipeIDs and T.GetRecipeSchematic) then return nil end
  local ids = Call(T.GetAllRecipeIDs)
  if type(ids) ~= "table" or #ids == 0 then return nil end
  local prof, rank
  local bp = Call(T.GetBaseProfessionInfo)
  if type(bp) == "table" then prof, rank = bp.professionName, bp.skillLevel end
  if not prof and T.GetTradeSkillLine then
    local _, n, r = Call(T.GetTradeSkillLine)
    prof, rank = n, r
  end
  local out = {}
  for _, rid in ipairs(ids) do
    local info = T.GetRecipeInfo and Call(T.GetRecipeInfo, rid)
    if type(info) == "table" then
      local s = Call(T.GetRecipeSchematic, rid, false)
      if type(s) == "table" and s.outputItemID then
        local reagents, ok = {}, true
        for _, slot in ipairs(s.reagentSlotSchematics or {}) do
          local first = slot.reagents and slot.reagents[1]
          -- skip optional/finishing slots; basic reagents have required quantities
          if first and first.itemID and (slot.quantityRequired or 0) > 0
            and (slot.reagentType == nil or slot.reagentType == 1) then
            reagents[#reagents + 1] = {first.itemID, slot.quantityRequired}
          elseif first and not first.itemID then
            ok = false
          end
        end
        if ok and #reagents > 0 then
          local learned = info.learned ~= false
          local r = {product = s.outputItemID, name = info.name,
            yield = ((s.quantityMin or 1) + (s.quantityMax or s.quantityMin or 1)) / 2,
            yieldMin = s.quantityMin or 1, yieldMax = s.quantityMax or s.quantityMin or 1,
            difficulty = learned and DIFF[info.relativeDifficulty] or nil, reagents = reagents,
            learned = learned}
          if T.GetRecipeRequirements then
            local req = Call(T.GetRecipeRequirements, rid)
            if type(req) == "table" then
              local names = {}
              for _, q in ipairs(req) do if type(q) == "table" and q.name then names[#names + 1] = q.name end end
              SetTools(r, names)
            end
          end
          out[#out + 1] = r
        end
      end
    end
  end
  return out, prof, rank
end

-- Classic API (GetTradeSkillInfo & co.).
local function ReadClassic()
  if not (GetNumTradeSkills and GetTradeSkillInfo) then return nil end
  local n = Call(GetNumTradeSkills) or 0
  if n == 0 then return nil end
  local prof, rank = Call(GetTradeSkillLine)
  local out = {}
  for i = 1, n do
    local name, kind = Call(GetTradeSkillInfo, i)
    if name and kind ~= "header" and kind ~= "subheader" then
      local product = IDFromLink(Call(GetTradeSkillItemLink, i))
      local lo, hi = Call(GetTradeSkillNumMade, i)
      local reagents, ok = {}, true
      for j = 1, (Call(GetTradeSkillNumReagents, i) or 0) do
        local _, _, count = Call(GetTradeSkillReagentInfo, i, j)
        local rid = IDFromLink(Call(GetTradeSkillReagentItemLink, i, j))
        if rid and count then reagents[#reagents + 1] = {rid, count} else ok = false end
      end
      if product and ok and #reagents > 0 then
        local r = {product = product, name = name, yield = ((lo or 1) + (hi or lo or 1)) / 2,
          yieldMin = lo or 1, yieldMax = hi or lo or 1,
          difficulty = DIFF[kind], reagents = reagents, learned = true}
        if GetTradeSkillTools then
          -- returns name1, have1, name2, have2, ...
          local t = {Call(GetTradeSkillTools, i)}
          local names = {}
          for k = 1, #t, 2 do if type(t[k]) == "string" and t[k] ~= "" then names[#names + 1] = t[k] end end
          SetTools(r, names)
        end
        out[#out + 1] = r
      end
    end
  end
  return out, prof, rank
end

-- Reads the open profession window into LedgerDB.recipes. Returns how many.
function ns.CaptureRecipes()
  local db = ns.db
  if not db then return 0 end
  local list, prof, rank = ReadModern()
  if not list or #list == 0 then list, prof, rank = ReadClassic() end
  if not list or #list == 0 or not prof or prof == "" then return 0 end
  db.recipes = db.recipes or {}
  db.recipeProfs = db.recipeProfs or {}
  local nLearned = 0
  for _, r in ipairs(list) do if r.learned then nLearned = nLearned + 1 end end
  -- replace this profession's window recipes wholesale (a filtered list would
  -- drop some, so only replace when we got at least as many as before).
  -- Recipes seen at a trainer (not learned yet) stay unless now learned.
  local before = 0
  for _, r in pairs(db.recipes) do if r.prof == prof and r.learned then before = before + 1 end end
  if nLearned >= before then
    for id, r in pairs(db.recipes) do
      if r.prof == prof and r.src ~= "trainer" then db.recipes[id] = nil end
    end
  end
  for _, r in ipairs(list) do
    local old = db.recipes[r.product]
    if r.learned or not (old and old.learned) then
      r.prof, r.t, r.src = prof, time(), "window"
      if not r.learned and old then r.trainCost, r.skill = old.trainCost, old.skill end
      db.recipes[r.product] = r
    end
  end
  local p = db.recipeProfs[prof] or {}
  local prevN = p.n
  p.t, p.rank, p.n = time(), rank, nLearned
  db.recipeProfs[prof] = p
  return nLearned, prof, prevN
end

-- Trainer window: recipes you can (or will be able to) learn, with reagents,
-- training cost and skill needed. Saved as not learned (src = "trainer").
-- Only what the trainer window lists is read; tick its "unavailable" filter to
-- include recipes above your current skill.
function ns.CaptureTrainer()
  local db = ns.db
  if not (db and GetNumTrainerServices and GetTrainerServiceInfo) then return 0 end
  db.recipes = db.recipes or {}
  local n, added = Call(GetNumTrainerServices) or 0, 0
  for i = 1, n do
    local name, _, category = Call(GetTrainerServiceInfo, i)
    if name and category ~= "header" and category ~= "used" then
      local product = IDFromLink(Call(GetTrainerServiceItemLink, i))
      local skillName, skillRank = Call(GetTrainerServiceSkillReq, i)
      local reagents, ok = {}, true
      for j = 1, (Call(GetTrainerServiceNumReagents, i) or 0) do
        local _, _, count = Call(GetTrainerServiceReagentInfo, i, j)
        local rid = IDFromLink(Call(GetTrainerServiceReagentLink, i, j))
        if rid and count then reagents[#reagents + 1] = {rid, count} else ok = false end
      end
      local old = product and db.recipes[product]
      if product and skillName and ok and #reagents > 0 and not (old and old.learned) then
        db.recipes[product] = {product = product, name = name, prof = skillName, skill = skillRank,
          yield = old and old.yield or 1, yieldMin = old and old.yieldMin, yieldMax = old and old.yieldMax,
          reagents = reagents, learned = false, src = "trainer",
          trainCost = Call(GetTrainerServiceCost, i), canLearn = category == "available", t = time()}
        added = added + 1
      end
    end
  end
  return added
end

local captureQueued = false
function ns.QueueCapture()
  if captureQueued then return end
  captureQueued = true
  C_Timer.After(1, function()
    captureQueued = false
    local n, prof, prevN = ns.CaptureRecipes()
    if n > 0 then
      -- speak only the first time, or when you've learned something new
      if prevN == nil then
        Print(string.format("recorded %d %s recipes for the crafting check (/ledger craft).", n, prof))
      elseif n > prevN then
        Print(string.format("%d new %s recipe%s added to the crafting check.", n - prevN, prof,
          n - prevN == 1 and "" or "s"))
      end
      if ns.RefreshUI then ns.RefreshUI() end
    end
  end)
end

local trainerQueued = false
local function QueueTrainer()
  if trainerQueued then return end
  trainerQueued = true
  C_Timer.After(1, function()
    trainerQueued = false
    if ns.CaptureTrainer() > 0 and ns.RefreshUI then ns.RefreshUI() end
  end)
end

local ev = CreateFrame("Frame")
for _, e in ipairs({"TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_UPDATE", "NEW_RECIPE_LEARNED",
  "TRAINER_SHOW", "TRAINER_UPDATE"}) do
  pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event)
  if not ns.db then return end
  if event == "TRAINER_SHOW" or event == "TRAINER_UPDATE" then QueueTrainer() else ns.QueueCapture() end
end)

------------------------------------------------------------------------
-- Yield tracking: how many items your crafts actually make
------------------------------------------------------------------------
-- While a profession window is open, a craft you start snapshots how many of
-- each known product are in your bags; a second after it succeeds they're
-- counted again and the one product that went up is recorded:
--   LedgerDB.yields[product] = {n = crafts, made = total, min, max, t}
-- Nothing is recorded when no product (bags full -> mail) or more than one
-- changed. Read-only: Ledger only counts, it never crafts.

local tradeOpen, snap, castSecs = false, nil, nil

local function BagCount(id)
  if not GetItemCount then return nil end
  local ok, n = pcall(GetItemCount, id)
  return ok and tonumber(n) or nil
end

local function SnapProducts()
  local counts = {}
  for id, r in pairs(ns.db and ns.db.recipes or {}) do
    if r.learned ~= false then counts[id] = BagCount(id) end
  end
  return counts
end

-- Cast time (v0.8.11): how long one craft takes, from the cast bar of the
-- crafts the yield tracking identifies: LedgerDB.craftTimes[product] = {n, total, t}
function ns.RecordCraftTime(product, secs)
  local db = ns.db
  if not (db and product and secs and secs > 0 and secs < 120) then return end
  db.craftTimes = db.craftTimes or {}
  local c = db.craftTimes[product] or {n = 0, total = 0}
  c.n, c.total, c.t = c.n + 1, c.total + secs, time()
  db.craftTimes[product] = c
end

function ns.RecordYield(product, made)
  local db = ns.db
  if not (db and product and made and made > 0) then return end
  db.yields = db.yields or {}
  local y = db.yields[product] or {n = 0, made = 0}
  y.n, y.made, y.t = y.n + 1, y.made + made, time()
  y.min = y.min and min(y.min, made) or made
  y.max = y.max and max(y.max, made) or made
  db.yields[product] = y
end

local function CompareSnap(before, secs)
  local hit, made, n = nil, 0, 0
  for id, was in pairs(before) do
    local now = BagCount(id)
    if was and now and now > was then
      hit, made, n = id, now - was, n + 1
      -- "Create all": the next craft's snapshot may predate these items
      -- arriving; move it up so they aren't counted twice
      if snap and snap[id] and snap[id] < now then snap[id] = now end
    end
  end
  if n == 1 then
    ns.RecordYield(hit, made)
    ns.RecordCraftTime(hit, secs)
    if ns.RefreshUI then ns.RefreshUI() end
  end
end

local yf = CreateFrame("Frame")
for _, e in ipairs({"TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED",
  "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED"}) do
  pcall(yf.RegisterEvent, yf, e)
end
yf:SetScript("OnEvent", function(_, event, unit)
  if not ns.db then return end
  if event == "TRADE_SKILL_SHOW" then tradeOpen = true; return end
  if event == "TRADE_SKILL_CLOSE" then tradeOpen = false; return end
  if unit ~= "player" then return end
  if event == "UNIT_SPELLCAST_START" then
    snap = tradeOpen and SnapProducts() or nil
    castSecs = nil
    if snap and UnitCastingInfo then
      local ok, _, _, _, startMS, endMS = pcall(UnitCastingInfo, "player")
      if ok and startMS and endMS and endMS > startMS then castSecs = (endMS - startMS) / 1000 end
    end
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    local before, secs = snap, castSecs
    snap, castSecs = nil, nil
    if before then C_Timer.After(1, function() CompareSnap(before, secs) end) end
  else
    snap, castSecs = nil, nil
  end
end)

------------------------------------------------------------------------
-- Margins
------------------------------------------------------------------------

-- What a vendor pays for one (copper; 0 = can't be sold; nil = item data not
-- loaded yet, a load is requested). Cached in LedgerDB.vendor like the
-- Below vendor tab's lookups.
function ns.VendorSell(itemID)
  local db = ns.db
  local cached = db and db.vendor and db.vendor[itemID]
  if cached ~= nil then return cached end
  local sell = ns.SellPrice and ns.SellPrice(itemID)   -- corrections first, then the item data
  if sell ~= nil and db then db.vendor = db.vendor or {}; db.vendor[itemID] = sell end
  return sell
end

-- Latest market numbers for an item: lowest, median, listed, age (days), source.
function ns.MarketPrice(itemID)
  local price, age, _, src, pt = ns.GetPrice(itemID)
  if not price then return nil end
  return {min = price, median = (pt and pt[3] and pt[3] > 0) and pt[3] or nil,
    listed = pt and pt[4] or nil, age = age, src = src, t = pt and pt[1] or nil}
end

-- Cheapest way to buy one: AH lowest buyout or vendor (trade supplies).
------------------------------------------------------------------------
-- Depth pricing (v0.8.3): a couple of units listed absurdly cheap shouldn't
-- set the price. With listing levels (AHDB scan or live search, see
-- ns.ListingLevels) Ledger uses:
--   buying a reagent: the average price of the cheapest BUY_UNITS units
--     (what buying enough for a batch really costs)
--   selling a product: the price after skipping the cheapest SKIP_UNITS units
--     (stragglers get bought out; the price you compete with is above them),
--     still capped at the median
-- Settings (units): settings.craftBuy (default 20), settings.craftSkip (default 5).
-- Without levels, the lowest buyout is used as before.
------------------------------------------------------------------------

local function DepthSetting(key, default)
  local v = ns.db and ns.db.settings and tonumber(ns.db.settings[key])
  return v or default
end
function ns.CraftBuyUnits() return DepthSetting("craftBuy", 20) end
function ns.CraftSkipUnits() return DepthSetting("craftSkip", 5) end

-- Average price of the cheapest `units` units, and whether the levels Ledger
-- has cover that many (if not, the rest are priced at the last level seen).
function ns.BuyAvg(itemID, units)
  local levels = ns.ListingLevels and ns.ListingLevels(itemID)
  if not levels or units <= 0 then return nil end
  local need, cost, last = units, 0, nil
  for _, l in ipairs(levels) do
    local take = min(need, l[3])
    cost, need, last = cost + take * l[1], need - take, l[1]
    if need <= 0 then break end
  end
  local covered = need <= 0
  if not covered then cost = cost + need * last end
  return floor(cost / units + 0.5), covered
end

-- Price of the first unit after skipping the cheapest `skip` units.
function ns.SellAt(itemID, skip)
  local levels = ns.ListingLevels and ns.ListingLevels(itemID)
  if not levels then return nil end
  local cum = 0
  for _, l in ipairs(levels) do
    cum = cum + l[3]
    if cum > skip then return l[1], true end
  end
  return levels[#levels][1], false   -- fewer than skip+1 units listed (that we know of)
end

-- Cheapest way to buy one, for a batch: AH depth average (or lowest buyout
-- without levels) or vendor (trade supplies).
local function BuyCost(itemID)
  local m = ns.MarketPrice(itemID)
  local v = ns.VendorBuyPrice(itemID)
  local ah = m and m.min
  if m then
    local avg = ns.BuyAvg(itemID, ns.CraftBuyUnits())
    if avg and avg > ah then ah = avg end
  end
  if v and (not ah or v <= ah) then return v, "vendor" end
  if ah then return ah, "ah" end
  return nil
end

-- A recipe's average output, blended with what your crafts actually made.
local function EffectiveYield(r)
  local y = r.yield or 1
  local seen = ns.db and ns.db.yields and ns.db.yields[r.product]
  if seen and (seen.n or 0) > 0 then y = (y * YIELD_PRIOR + seen.made) / (YIELD_PRIOR + seen.n) end
  return y
end

-- Make-or-buy: a reagent you can craft yourself (a learned recipe) costs the
-- cheaper of buying it and crafting it from its own reagents, which are priced
-- the same way, up to MAKE_DEPTH levels deep (e.g. Heavy Stone -> Heavy
-- Blasting Powder -> Heavy Dynamite). Returns a function
--   cost(itemID, depth, visiting) -> each, how ("ah"|"vendor"|"craft"), parts, buyEach, buyHow
-- where parts lists the sub-reagents when how == "craft". Results are cached
-- for one CraftMargins pass.
local MAKE_DEPTH = 3
-- How intermediate reagents are sourced (settings.craftSource, v0.8.8):
--   "cheapest" (default) buy or craft, whichever costs less
--   "ah"       buy every reagent; craft one only when it can't be bought
--   "craft"    craft every reagent you have the recipe for; buy only what you
--              can't craft (or what a vendor sells for less than crafting it)
ns.CRAFT_SOURCES = {"cheapest", "ah", "craft"}
function ns.CraftSource()
  local s = ns.db and ns.db.settings and ns.db.settings.craftSource
  if s == "ah" or s == "craft" then return s end
  return "cheapest"
end

-- No-anvil mode (settings.craftNoAnvil, v0.8.14): for crafting where you are,
-- e.g. at the auction house. Recipes that need an anvil are left out, both as
-- rows and as parts to craft (those parts are bought instead). Only recipes read
-- from a profession window know their tools; others are kept.
function ns.CraftNoAnvil()
  return ns.db and ns.db.settings and ns.db.settings.craftNoAnvil and true or false
end

local function MakeCoster(byProduct, mode)
  mode = mode or "cheapest"
  local memo = {}
  local function cost(id, depth, visiting)
    local hit = memo[id]
    if hit then return hit[1], hit[2], hit[3], hit[4], hit[5] end
    local buyEach, buyHow = BuyCost(id)
    local best, how, parts = buyEach, buyHow, nil
    local r = byProduct[id]
    if r and depth <= MAKE_DEPTH and not visiting[id] then
      visiting[id] = true
      local total, ok, list = 0, true, {}
      for _, rg in ipairs(r.reagents or {}) do
        local e, h, sub, be, bh = cost(rg[1], depth + 1, visiting)
        if not e then ok = false; break end
        total = total + e * rg[2]
        list[#list + 1] = {id = rg[1], n = rg[2], each = e, how = h, parts = sub, buyEach = be, buyHow = bh}
      end
      visiting[id] = nil
      if ok then
        local y = EffectiveYield(r)
        list.yield = y   -- how many one craft of this intermediate makes (for break-even prices)
        local each = total / y
        local take
        if not best then take = true
        elseif mode == "ah" then take = false
        elseif mode == "craft" then take = not (buyHow == "vendor" and best < each)
        else take = each < best end
        if take then best, how, parts = each, "craft", list end
      end
    end
    memo[id] = {best, how, parts, buyEach, buyHow}
    return best, how, parts, buyEach, buyHow
  end
  return cost
end

-- Professions the crafting check covers even before you open their window
-- (their GearQuest recipes show as not learned). The Crafting tab shows one at a
-- time: yours first (the ones whose window you've opened), Engineering when none.
ns.CRAFT_PROFS = {"Engineering", "Tailoring", "Blacksmithing"}

-- Professions in the order the Crafting tab cycles them (v0.9.0): the ones
-- you've opened (in CRAFT_PROFS order, then any others), then the rest.
function ns.CraftProfList()
  local captured = ns.db and ns.db.recipeProfs or {}
  local out, seen = {}, {}
  local function add(name) if name and name ~= "" and not seen[name] then seen[name] = true; out[#out + 1] = name end end
  for _, name in ipairs(ns.CRAFT_PROFS) do if captured[name] then add(name) end end
  local extra = {}
  for name in pairs(captured) do if not seen[name] and name ~= "" then extra[#extra + 1] = name end end
  table.sort(extra)
  for _, name in ipairs(extra) do add(name) end
  for _, name in ipairs(ns.CRAFT_PROFS) do add(name) end
  return out
end

-- Your main crafting profession: the first one you've opened, else Engineering.
function ns.MainCraftProf()
  return ns.CraftProfList()[1] or "Engineering"
end

-- Your skill in a profession, as last read from its window (nil if never).
function ns.ProfRank(prof)
  local p = ns.db and ns.db.recipeProfs and ns.db.recipeProfs[prof]
  return p and p.rank or nil
end

-- All recipes, each with learned = true/false and src:
--   "window"    read from your profession window (learned, or unlearned on clients that list them)
--   "trainer"   seen at a trainer, not learned yet (has trainCost and skill)
--   "gearquest" GearQuestForever's recipe data (gear recipes, from Wowhead Forever), not learned
--   "seed"      Ledger's built-in Engineering guesses
-- Before any Engineering window has been read, the seeds stand in for your
-- known Engineering recipes (learned = true, seed = true).
function ns.Recipes()
  local db = ns.db
  local out, have = {}, {}
  local captured = db and db.recipeProfs or {}
  local function add(r) if not have[r.product] then have[r.product] = true; out[#out + 1] = r end end
  for _, r in pairs(db and db.recipes or {}) do
    r.learned = r.learned ~= false
    add(r)
  end
  -- your professions: read ones, plus Engineering (the seeds' profession) and Tailoring
  local profs = {}
  for _, name in ipairs(ns.CRAFT_PROFS) do profs[name] = true end
  for name in pairs(captured) do profs[name] = true end
  local gq = GearQuest and GearQuest.CraftSkills
  if type(gq) == "table" then
    for product, c in pairs(gq) do
      if type(c) == "table" and profs[c.profession] and not have[product] and type(c.reagents) == "table" then
        local reagents = {}
        for i, rg in ipairs(c.reagents) do reagents[i] = {rg[1], rg[2]} end
        add({product = product, prof = c.profession, skill = c.skill, yield = 1,
          reagents = reagents, learned = false, src = "gearquest"})
      end
    end
  end
  for _, s in ipairs(SEED_RECIPES) do
    if not have[s[1]] then
      local reagents = {}
      for i, rg in ipairs(s[5]) do reagents[i] = {rg[1], rg[2]} end
      add({product = s[1], name = s[2], yield = s[3], skill = s[4], prof = "Engineering", reagents = reagents,
        -- stand in for your recipes only until you've opened any profession window
        seed = true, src = "seed", learned = next(captured) == nil})
    end
  end
  return out
end

-- One row per recipe:
--   id, name, prof, skill, difficulty, seed, yield, cost, sellEach, sell (after cut, x yield),
--   profit, roi, listed, median, low, age, reagents = {{id, n, each, how}}, missing (count)
function ns.CraftMargins()
  local rows = {}
  local recipes = ns.Recipes()
  if ns.CraftNoAnvil() then
    local keep = {}
    for _, r in ipairs(recipes) do if not r.anvil then keep[#keep + 1] = r end end
    recipes = keep
  end
  local byProduct = {}
  for _, r in ipairs(recipes) do
    if r.learned ~= false and not byProduct[r.product] then byProduct[r.product] = r end
  end
  local mode = ns.CraftSource()
  local cost = MakeCoster(byProduct, mode)
  -- other modes: also the cheapest mix, to say what the chosen one costs extra
  local cheap = mode ~= "cheapest" and MakeCoster(byProduct, "cheapest") or nil
  for _, r in ipairs(recipes) do
    local row = {id = r.product, name = r.name, prof = r.prof, skill = r.skill, difficulty = r.difficulty,
      seed = r.seed, yield = r.yield or 1, cost = 0, missing = 0, reagents = {},
      yieldMin = r.yieldMin or r.yield or 1, yieldMax = r.yieldMax or r.yield or 1,
      learned = r.learned ~= false, src = r.src, trainCost = r.trainCost, canLearn = r.canLearn,
      tools = r.tools, anvil = r.anvil, toolsRead = r.toolsRead}
    -- what your own crafts actually made (see "Yield tracking"): blended with
    -- the recipe's average, weighted as if it were YIELD_PRIOR crafts
    local seen = ns.db and ns.db.yields and ns.db.yields[r.product]
    if seen and (seen.n or 0) > 0 then
      row.seenN, row.seenAvg, row.seenMin, row.seenMax = seen.n, seen.made / seen.n, seen.min, seen.max
      row.recipeYield = row.yield
      row.yield = (row.yield * YIELD_PRIOR + seen.made) / (YIELD_PRIOR + seen.n)
      row.yieldMin = min(row.yieldMin, seen.min or row.yieldMin)
      row.yieldMax = max(row.yieldMax, seen.max or row.yieldMax)
    end
    if not row.learned and row.skill then
      local rank = ns.ProfRank(row.prof)
      if rank then row.canLearn = row.skill <= rank end
    end
    local buyAll, crafted = 0, {}
    for _, rg in ipairs(r.reagents or {}) do
      local each, how, parts, buyEach, buyHow = cost(rg[1], 1, {[r.product] = true})
      row.reagents[#row.reagents + 1] = {id = rg[1], n = rg[2], each = each, how = how, parts = parts,
        buyEach = buyEach, buyHow = buyHow}
      if each then row.cost = row.cost + each * rg[2] else row.missing = row.missing + 1 end
      if buyEach and buyAll then buyAll = buyAll + buyEach * rg[2] else buyAll = nil end
      if how == "craft" then crafted[#crafted + 1] = rg[1] end
    end
    row.cost = floor(row.cost + 0.5)
    if cheap and row.missing == 0 then
      local c = 0
      for _, rg in ipairs(r.reagents or {}) do
        local e = cheap(rg[1], 1, {[r.product] = true})
        if not e then c = nil; break end
        c = c + e * rg[2]
      end
      if c then row.costCheapest = floor(c + 0.5) end
    end
    row.source = mode
    -- what crafting the intermediates yourself saves over buying every reagent
    if #crafted > 0 then
      row.crafted = crafted
      row.costBuy = buyAll and floor(buyAll + 0.5) or nil
      row.saved = row.costBuy and (row.costBuy - row.cost) or nil
    end
    local m = ns.MarketPrice(r.product)
    if m then
      row.low, row.median, row.listed, row.age = m.min, m.median, m.listed, m.age
      row.priceSrc, row.priceT = m.src, m.t
      -- sell price: past the cheapest few stragglers (depth), capped at the median
      local base = m.min
      local at = ns.SellAt(r.product, ns.CraftSkipUnits())
      if at and at > base then base, row.skipped = at, true end
      row.ahEach = m.median and min(base, m.median) or base
      row.ahNet = floor(row.ahEach * row.yield * (1 - ns.AH_CUT))
    end
    -- vendor floor: what a vendor pays for the whole craft, no cut, no risk
    local vend = ns.VendorSell(r.product)
    if vend and vend > 0 then
      row.vendorEach = vend
      row.vendorNet = floor(vend * row.yield)
    end
    if row.ahNet or row.vendorNet then
      if row.vendorNet and (not row.ahNet or row.vendorNet >= row.ahNet) then
        row.sell, row.sellBy, row.sellEach = row.vendorNet, "vendor", row.vendorEach
      else
        row.sell, row.sellBy, row.sellEach = row.ahNet, "ah", row.ahEach
      end
      if row.missing == 0 and row.vendorNet then
        -- floor: average profit selling to a vendor; worst: one craft that makes the minimum
        row.floor = row.vendorNet - row.cost
        row.worst = floor(row.vendorEach * row.yieldMin) - row.cost
      end
      if row.missing == 0 then
        row.profit = row.sell - row.cost
        row.roi = row.cost > 0 and row.profit / row.cost or nil
        -- crafts until the training cost is earned back
        if not row.learned and row.trainCost and row.trainCost > 0 and row.profit > 0 then
          row.payback = math.ceil(row.trainCost / row.profit)
        end
        ns.BreakEven(row)
        ns.CraftTime(row)
      end
    end
    rows[#rows + 1] = row
  end
  table.sort(rows, function(a, b)
    if (a.profit ~= nil) ~= (b.profit ~= nil) then return a.profit ~= nil end
    if a.profit and b.profit and a.profit ~= b.profit then return a.profit > b.profit end
    return (a.name or "") < (b.name or "")
  end)
  return rows
end

-- Break-even reagent prices: for every reagent (and every sub-reagent down a
-- make-or-buy chain) the most you could pay for one, with everything else at
-- today's price, before a craft stops making money:
--   rg.maxVendor  selling the product to a vendor (guaranteed)
--   rg.maxSell    selling it the best way (the AH when it pays more)
-- A sub-reagent's units per craft = reagent count x its count / the
-- intermediate's yield (e.g. 2 powder x 1 stone / 1 = 2 stone per craft).
-- Seconds one craft of `product` takes, as you've timed it (nil if never).
function ns.CraftSecs(product)
  local ct = ns.db and ns.db.craftTimes
  local c = ct and ct[product]
  if c and c.n > 0 then return c.total / c.n end
  return nil
end

-- Time per craft including the intermediate parts you craft (per the Mats mode),
-- and profit per hour when vendoring the products (row.floor: vendor pays minus
-- mats, v0.8.13): row.secs, row.subCrafts, row.perHour, and row.untimed =
-- {itemIDs} of the recipe and parts not timed yet. Per hour is only given when
-- every craft involved has been timed.
function ns.CraftTime(row)
  local untimed = {}
  local secs = ns.CraftSecs(row.id)
  if not secs then untimed[#untimed + 1] = row.id; secs = 0 end
  local subs = 0
  local function walk(list, mult)
    for _, rg in ipairs(list or {}) do
      if rg.how == "craft" and rg.parts then
        local y = (rg.parts.yield and rg.parts.yield > 0) and rg.parts.yield or 1
        local crafts = mult * rg.n / y
        local s = ns.CraftSecs(rg.id)
        if s then secs = secs + crafts * s else untimed[#untimed + 1] = rg.id end
        subs = subs + crafts
        walk(rg.parts, crafts)
      end
    end
  end
  walk(row.reagents, 1)
  row.subCrafts = subs
  if #untimed > 0 then row.untimed = untimed; return end
  row.secs = secs
  if row.floor and secs > 0 then row.perHour = floor(row.floor * 3600 / secs) end
end

function ns.BreakEven(row)
  local function walk(list, mult)
    for _, rg in ipairs(list or {}) do
      local units = mult * rg.n
      if rg.each and units > 0 then
        local others = row.cost - rg.each * units
        rg.units = units
        if row.vendorNet then rg.maxVendor = floor((row.vendorNet - others) / units) end
        if row.sell then rg.maxSell = floor((row.sell - others) / units) end
        if rg.parts and (rg.parts.yield or 0) > 0 then
          -- sub-reagent lists are shared between recipes (make-or-buy cache): copy before writing
          local copy = {yield = rg.parts.yield}
          for i, p in ipairs(rg.parts) do
            copy[i] = {id = p.id, n = p.n, each = p.each, how = p.how, parts = p.parts, buyEach = p.buyEach,
              buyHow = p.buyHow}
          end
          rg.parts = copy
          walk(copy, units / copy.yield)
        end
      end
    end
  end
  walk(row.reagents, 1)
end

-- Items to search at the AH for the given craft rows: each product and every
-- reagent down the make-or-buy chain, skipping trade supplies bought from a
-- vendor. Most profitable recipes first.
function ns.CraftRefreshIDs(rows)
  local ids, seen = {}, {}
  local function add(id)
    if id and not seen[id] and not ns.VendorBuyPrice(id) then seen[id] = true; ids[#ids + 1] = id end
  end
  local function addParts(list)
    for _, rg in ipairs(list or {}) do
      add(rg.id)
      if rg.parts then addParts(rg.parts) end
    end
  end
  local sorted = {}
  for i, r in ipairs(rows) do sorted[i] = r end
  table.sort(sorted, function(a, b) return (a.profit or -1e12) > (b.profit or -1e12) end)
  for _, r in ipairs(sorted) do
    add(r.id)
    addParts(r.reagents)
  end
  return ids
end

-- What to buy for `crafts` crafts of a Crafting-tab row, following its reagent
-- tree (so the Mats mode decides what is crafted): parts you craft are expanded
-- into their own reagents, rounding up to whole crafts at their average yield.
-- Returns ah = {{id, qty, each}}, vendor = {{id, qty, each}}, unpriced = {{id, qty}},
-- each in the order first needed, plus cost (AH + vendor, copper) and costAH.
function ns.CraftShoppingList(row, crafts)
  local out = {ah = {}, vendor = {}, unpriced = {}, cost = 0, costAH = 0}
  local at = {}
  local function add(kind, id, qty, each)
    if each and kind ~= "unpriced" then
      out.cost = out.cost + each * qty
      if kind == "ah" then out.costAH = out.costAH + each * qty end
    end
    local key = kind .. id
    if at[key] then at[key].qty = at[key].qty + qty; return end
    local e = {id = id, qty = qty, each = each}
    at[key] = e
    table.insert(out[kind], e)
  end
  local function walk(list, mult)
    for _, rg in ipairs(list or {}) do
      local qty = mult * rg.n
      if rg.how == "craft" and rg.parts then
        local y = (rg.parts.yield and rg.parts.yield > 0) and rg.parts.yield or 1
        walk(rg.parts, math.ceil(qty / y - 1e-9))
      elseif rg.how == "vendor" then add("vendor", rg.id, qty, rg.each)
      elseif rg.how == "ah" then add("ah", rg.id, qty, rg.each)
      else add("unpriced", rg.id, qty) end
    end
  end
  walk(row and row.reagents, crafts or 1)
  out.cost, out.costAH = floor(out.cost + 0.5), floor(out.costAH + 0.5)
  return out
end

-- Fees on open loans: the profit a loan has to earn back.
function ns.LoanFeesOpen()
  local fees = 0
  for _, l in ipairs(ns.OpenLoans and ns.OpenLoans() or {}) do fees = fees + (l.fee or 0) end
  return fees
end

-- How many crafts (and listings sold) it takes to make `goal` copper.
function ns.CraftsFor(row, goal)
  if not (row and row.profit and row.profit > 0 and goal and goal > 0) then return nil end
  return math.ceil(goal / row.profit)
end

-- Chat report: best earners, then recipes that cost more to craft than to buy.
-- " x3", " x1-5 (avg 3.2)" or "" for single-item crafts.
function ns.YieldText(r)
  local lo, hi = r.yieldMin or r.yield, r.yieldMax or r.yield
  if lo == hi then return r.yield ~= 1 and (" x" .. r.yield) or "" end
  return string.format(" x%d-%d (avg %.1f)", lo, hi, r.yield)
end

-- Name (or clickable link) for a recipe row.
local function RowLabel(r)
  local name, link = ns.ItemInfo(r.id)
  return link or name or r.name or ("item " .. r.id)
end

-- mode nil: recipes you know. mode "new": recipes you haven't learned yet.
-- prof: only that profession's recipes (nil = all)
function ns.ReportCraft(limit, mode, prof)
  limit = limit or 8
  local newOnly = mode == "new"
  local rows = ns.CraftMargins()
  if prof then
    local keep = {}
    for _, r in ipairs(rows) do if r.prof == prof then keep[#keep + 1] = r end end
    rows = keep
  end
  if #rows == 0 then Print("no recipes yet - open your profession window once."); return end
  local seed = false
  for _, r in ipairs(rows) do if r.seed and r.learned then seed = true; break end end
  local goal = ns.LoanFeesOpen and ns.LoanFeesOpen() or 0
  if newOnly then
    -- learnable now first, then the rest; each by profit
    local copy = {}
    for i, r in ipairs(rows) do copy[i] = r end
    table.sort(copy, function(a, b)
      local ca, cb = a.canLearn and 1 or 0, b.canLearn and 1 or 0
      if ca ~= cb then return ca > cb end
      return (a.profit or -1e12) > (b.profit or -1e12)
    end)
    rows = copy
  end
  Print(newOnly and "best recipes you haven't learned yet (profit per craft, after the 5% cut):"
    or "best crafts now (profit per craft, after the 5% cut):")
  local shown = 0
  for _, r in ipairs(rows) do
    if r.learned ~= newOnly and r.profit and r.profit > 0 and shown < limit then
      shown = shown + 1
      local extra
      if newOnly then
        local where = r.src == "trainer" and ("trainer" .. (r.trainCost and (" " .. ns.Money(r.trainCost)) or ""))
          or (r.src == "gearquest" and "recipe/trainer, see GearQuest") or "built-in guess"
        extra = string.format(" - %s %s%s, %s%s", r.canLearn and "|cff33ff33can learn now|r:" or "needs",
          r.prof or "?", r.skill and (" " .. r.skill) or "",
          where, r.payback and string.format(", pays back in %d crafts", r.payback) or "")
      else
        local n = goal > 0 and ns.CraftsFor(r, goal)
        extra = n and string.format(" - %d crafts cover your loan fees", n) or ""
      end
      local how
      if r.sellBy == "vendor" then
        how = " to a vendor (no risk)"
      elseif r.floor and r.floor > 0 then
        how = string.format(" on the AH (vendor floor %s%s)", ns.Money(r.floor),
          (r.worst and r.worst < 0) and " on average" or "")
      else
        how = " on the AH"
      end
      if r.crafted then
        local names = {}
        for i, id in ipairs(r.crafted) do names[i] = RowLabel({id = id}) end
        extra = extra .. " - craft your own " .. table.concat(names, ", ")
          .. (r.saved and r.saved > 0 and (" (saves " .. ns.Money(r.saved) .. ")") or "")
      end
      Print(string.format("  %s%s: mats %s, sells %s%s%s, profit %s (%+.0f%%), %s listed%s",
        RowLabel(r), ns.YieldText(r), ns.Money(r.cost), ns.Money(r.sellEach),
        r.yield ~= 1 and " each" or "", how, ns.Money(r.profit), (r.roi or 0) * 100,
        tostring(r.listed or "?"), extra))
    end
  end
  if shown == 0 then
    Print(newOnly and "  nothing profitable among unlearned recipes (visit your trainer to add its list)."
      or "  nothing profitable right now.")
  end
  if not newOnly then
    local buy = {}
    for _, r in ipairs(rows) do
      if r.learned and r.profit and r.profit < 0 and r.sell and r.sell > 0 then buy[#buy + 1] = r end
    end
    table.sort(buy, function(a, b) return a.profit < b.profit end)
    if #buy > 0 then
      local names = {}
      for i = 1, min(6, #buy) do names[i] = RowLabel(buy[i]) end
      Print("cheaper to buy than craft: " .. table.concat(names, ", ") .. (#buy > 6 and (" (+" .. (#buy - 6) .. ")") or ""))
    end
    Print("/ledger craft new lists recipes you haven't learned yet.")
  end
  if seed then
    Print("|cffff9933Engineering recipes are Ledger's built-in guesses - open your Engineering window to use your real ones.|r")
  end
  Print("Prices are listings, not sales: check how fast an item sells before making many.")
end
