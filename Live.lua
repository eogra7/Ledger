-- Ledger: live AH prices (v0.8). Read-only: it searches, it never buys, bids, posts or cancels.
--
-- Passive: whenever any item search finishes at the open AH (yours, Auctionator's, AHDB's), its result is
-- recorded. Active: ns.LiveRefresh(ids) searches a list of items one at a time (the Crafting tab's "Refresh
-- from AH" button), politely:
--   * only while the AH is open, and never during an AHDB scan or right after someone else's AH query
--     (AuctionDB.scanState / AuctionDB.ahBusy / another query in the last QUIET s); AuctionDB.ahBusy is set while
--     Ledger searches, so AHDB's own live searches wait too
--   * a query is resent (up to TRIES) when the client didn't send it (no AUCTION_HOUSE_THROTTLED_MESSAGE_SENT),
--     a Forever quirk documented in AHDB's Live.lua
--   * no results event comes when the results didn't change: after WAIT s, whatever is there is read
--
-- Saved in LedgerDB.live.items[itemID] = {t, min, median, qty, levels = "price,auctions,units ...", full}
-- (levels like LedgerDB.listings). Core's GetPrice prefers it when newer than AHDB's scan and < 6 hours old.

local _, ns = ...
local floor, min = math.floor, math.min
local Print = ns.Print

local RESEND, TRIES, WAIT, QUIET, GAP = 1, 5, 8, 3, 0.3
local LEVELS_MAX = 25

local ahOpen = false
local ours = false       -- our own SendSearchQuery is being called
local sent = 0           -- AUCTION_HOUSE_THROTTLED_MESSAGE_SENT count
local lastForeign = 0    -- last AH query from someone else (GetTime)
local run                -- active refresh: {queue, i, done, onUpdate, current = {id, key, t}}

local function Now() return GetTime and GetTime() or time() end

------------------------------------------------------------------------
-- Recording results
------------------------------------------------------------------------

-- units = {{unitPrice, count}, ...} -> min, quantity-weighted median, qty, levels string
local function Stats(units)
  table.sort(units, function(a, b) return a[1] < b[1] end)
  local qty = 0
  for _, u in ipairs(units) do qty = qty + u[2] end
  if qty == 0 then return nil end
  local half, acc, median = qty / 2, 0, nil
  for _, u in ipairs(units) do
    acc = acc + u[2]
    if acc >= half then median = u[1]; break end
  end
  local parts, last = {}, nil
  for _, u in ipairs(units) do
    if last and last[1] == u[1] then
      last[2], last[3] = last[2] + u[3], last[3] + u[2]
    else
      if #parts >= LEVELS_MAX then break end
      last = {u[1], u[3], u[2]}
      parts[#parts + 1] = last
    end
  end
  for i, l in ipairs(parts) do parts[i] = l[1] .. "," .. l[2] .. "," .. l[3] end
  return units[1][1], median, qty, table.concat(parts, " ")
end

function ns.RecordLive(itemID, units, full)
  local db = ns.db
  if not (db and itemID) then return end
  db.live = db.live or {items = {}}
  db.live.items = db.live.items or {}
  if #units == 0 then
    db.live.items[itemID] = {t = time(), none = true}
    return
  end
  local lo, median, qty, levels = Stats(units)
  if not lo then return end
  db.live.items[itemID] = {t = time(), min = lo, median = median, qty = qty, levels = levels, full = full}
end

-- {{unitPrice, quantity, auctions}, ...} from the client's loaded results
local function ReadCommodity(itemID)
  local A = C_AuctionHouse
  local units = {}
  for i = 1, (A.GetNumCommoditySearchResults(itemID) or 0) do
    local r = A.GetCommoditySearchResultInfo(itemID, i)
    if r and r.unitPrice and r.unitPrice > 0 then
      -- a commodity row merges auctions at one price; numOwnerItems etc. aside, count it as one listing
      units[#units + 1] = {r.unitPrice, r.quantity or 1, 1}
    end
  end
  local full = A.HasFullCommoditySearchResults and A.HasFullCommoditySearchResults(itemID)
  return units, full
end

local function ReadItem(itemKey)
  local A = C_AuctionHouse
  local units = {}
  for i = 1, (A.GetNumItemSearchResults(itemKey) or 0) do
    local r = A.GetItemSearchResultInfo(itemKey, i)
    -- Forever groups identical auctions in one row: quantity = how many, buyoutAmount = one of them
    if r and r.buyoutAmount and r.buyoutAmount > 0 then
      local n = math.max(r.quantity or 1, 1)
      units[#units + 1] = {r.buyoutAmount, n, n}
    end
  end
  local full = A.HasFullItemSearchResults and A.HasFullItemSearchResults(itemKey)
  return units, full
end

------------------------------------------------------------------------
-- Active refresh queue
------------------------------------------------------------------------

local function AHDBBusy()
  local adb = AuctionDB
  return adb and (adb.scanState or (adb.ahBusy and adb.ahBusy ~= "Ledger")) or false
end

local function Busy()
  return AHDBBusy() or (Now() - lastForeign < QUIET)
end

local Step

local function Finish(reason)
  local r = run
  run = nil
  if AuctionDB and AuctionDB.ahBusy == "Ledger" then AuctionDB.ahBusy = nil end
  if r then
    if r.onUpdate then pcall(r.onUpdate, r.done, #r.queue, reason) end
    Print(string.format("live prices: %d of %d items searched%s.", r.done, #r.queue,
      reason and (" (" .. reason .. ")") or ""))
  end
  if ns.SnapPrices then ns.SnapPrices() end
  if ns.RefreshUI then ns.RefreshUI() end
end

local function Send(c, tries)
  local before = sent
  ours = true
  pcall(C_AuctionHouse.SendSearchQuery, c.key, {{sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false}}, true)
  ours = false
  C_Timer.After(RESEND, function()
    if run and run.current == c and sent == before and tries < TRIES then Send(c, tries + 1) end
  end)
end

local function Got(c)
  if not run or run.current ~= c then return end
  run.current = nil
  run.done = run.done + 1
  if run.onUpdate then pcall(run.onUpdate, run.done, #run.queue) end
  C_Timer.After(GAP, Step)
end

Step = function()
  local r = run
  if not r then return end
  if not ahOpen then Finish("AH closed"); return end
  if Busy() then C_Timer.After(0.5, Step); return end
  r.i = r.i + 1
  local id = r.queue[r.i]
  if not id then Finish(); return end
  if AuctionDB then AuctionDB.ahBusy = "Ledger" end
  local c = {id = id, key = C_AuctionHouse.MakeItemKey(id), t = Now()}
  r.current = c
  Send(c, 1)
  -- no event when nothing changed since an earlier search: read what's there
  C_Timer.After(WAIT, function()
    if not run or run.current ~= c then return end
    local A = C_AuctionHouse
    if (A.GetNumCommoditySearchResults(id) or 0) > 0 then
      ns.RecordLive(id, ReadCommodity(id))
    elseif (A.GetNumItemSearchResults(c.key) or 0) > 0 then
      ns.RecordLive(id, ReadItem(c.key))
    else
      ns.RecordLive(id, {})   -- none listed right now
    end
    Got(c)
  end)
end

-- Search these item ids at the open AH. Returns false (and why) if it can't start.
function ns.LiveRefresh(ids, onUpdate)
  if run then return false, "already refreshing" end
  if not ahOpen then return false, "open the auction house first" end
  if not (C_AuctionHouse and C_AuctionHouse.SendSearchQuery and C_AuctionHouse.MakeItemKey) then
    return false, "this client has no AH search API"
  end
  local queue, seen = {}, {}
  for _, id in ipairs(ids or {}) do
    if id and not seen[id] then seen[id] = true; queue[#queue + 1] = id end
  end
  if #queue == 0 then return false, "nothing to search" end
  run = {queue = queue, i = 0, done = 0, onUpdate = onUpdate}
  Print(string.format("live prices: searching %d items at the AH (~%ds)...", #queue, floor(#queue * 1.2 + 0.5)))
  Step()
  return true
end

function ns.LiveStop() if run then Finish("stopped") end end

-- nil when idle, else done, total
function ns.LiveProgress()
  if not run then return nil end
  return run.done, #run.queue
end

function ns.AHOpen() return ahOpen end

-- How many items have a live price right now, and the newest one's time.
function ns.LiveSummary()
  local n, newest = 0, nil
  for id in pairs(ns.db and ns.db.live and ns.db.live.items or {}) do
    local l = ns.LivePrice(id)
    if l then n = n + 1; if not newest or l.t > newest then newest = l.t end end
  end
  return n, newest
end

------------------------------------------------------------------------
-- Show an item in the AH's buy view (Below vendor tab click)
------------------------------------------------------------------------
-- Opens Blizzard's own buy screen for the item, the way Auctionator does
-- (AuctionHouseFrame:SelectBrowseResult). Nothing is bought: you choose the
-- quantity and click Buy yourself. If the AH is closed, it opens the item next
-- time you open the AH. The item's AH info has to be loaded first
-- (ITEM_KEY_ITEM_INFO_RECEIVED), so it may take a moment the first time.

local pendingShow   -- {id, price, qty, t}

local function TryShow(p)
  local A = C_AuctionHouse
  if not (AuctionHouseFrame and AuctionHouseFrame.SelectBrowseResult and A and A.MakeItemKey) then
    return true, "this client's AH window can't be opened from an add-on"
  end
  local key = A.MakeItemKey(p.id)
  local info = A.GetItemKeyInfo and A.GetItemKeyInfo(key)
  if not info then return false end            -- not loaded yet; wait for ITEM_KEY_ITEM_INFO_RECEIVED
  local ok, err = pcall(AuctionHouseFrame.SelectBrowseResult, AuctionHouseFrame,
    {itemKey = key, minPrice = p.price, totalQuantity = p.qty or 0})
  AuctionHouseFrame.displayMode = nil          -- as Auctionator does: keeps bag item clicks working
  if not ok then return true, tostring(err) end
  -- commodities: start the quantity at what's listed under vendor price (you still click Buy)
  if info.isCommodity and p.qty and p.qty > 0 then
    local bf = AuctionHouseFrame.CommoditiesBuyFrame
    local input = bf and bf.BuyDisplay and bf.BuyDisplay.QuantityInput
    if input and input.SetQuantity then pcall(input.SetQuantity, input, p.qty) end
  end
  return true
end

-- price: lowest buyout (used for commodities); qty: suggested quantity (optional)
function ns.ShowInAH(itemID, price, qty)
  local p = {id = itemID, price = price, qty = qty, t = Now()}
  if not ahOpen then
    pendingShow = p
    Print("open the auction house and Ledger will show that item there.")
    return
  end
  local done, err = TryShow(p)
  if not done then
    pendingShow = p   -- retried when the item's AH info arrives (or on the next click)
    if C_AuctionHouse.GetItemKeyInfo then C_AuctionHouse.GetItemKeyInfo(C_AuctionHouse.MakeItemKey(itemID)) end
    C_Timer.After(3, function()
      if pendingShow == p then pendingShow = nil; Print("the AH didn't return that item's info; click it again.") end
    end)
  elseif err then
    Print("couldn't open that item in the AH: " .. err)
  end
end

------------------------------------------------------------------------
-- Shopping list for a craft (v0.8.9): Crafting tab, right-click > 1x / 10x.
-- Builds an Auctionator shopping list "Ledger: <product>" with every reagent
-- to buy on the AH and its quantity (Auctionator's quantity field), replacing
-- the previous one of that name. With the AH open it switches to Auctionator's
-- Shopping tab and searches the list; otherwise it does that when you next
-- open the AH. Searching only: you choose what to buy.
------------------------------------------------------------------------

local pendingShop   -- {name, t}

local function ItemName(id)
  local ok, name = pcall(GetItemInfo, id)
  if ok and name then return name end
  if C_Item and C_Item.GetItemNameByID then
    local ok2, n2 = pcall(C_Item.GetItemNameByID, id)
    if ok2 and n2 then return n2 end
  end
  if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
  return nil
end

-- Switches the AH to Auctionator's Shopping tab and searches list `name`.
local function OpenShop(name)
  local A = Auctionator
  if not (A and A.Shopping and A.Shopping.ListManager and A.EventBus and AuctionatorTabs_Shopping) then
    return false
  end
  local ok = pcall(function()
    local list = A.Shopping.ListManager:GetByName(name)
    if not list then error("no list") end
    AuctionatorTabs_Shopping:Click()
    local src = {}
    A.EventBus:RegisterSource(src, "Ledger shopping list")
      :Fire(src, A.Shopping.Tab.Events.ListSearchRequested, list)
      :UnregisterSource(src)
  end)
  return ok
end

local function TryOpenShop(p)
  if OpenShop(p.name) then return end
  Print("shopping list \"" .. p.name .. "\" is in Auctionator's Shopping tab.")
end

function ns.ShopForCraft(row, crafts, tries)
  if not row then return end
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  local list = ns.CraftShoppingList(row, crafts)
  local product = ItemName(row.id) or row.name or ("item " .. row.id)

  -- names are needed for Auctionator's exact search; ask the client and retry
  local missing = false
  for _, e in ipairs(list.ah) do
    e.name = ItemName(e.id)
    if not e.name then missing = true end
  end
  if missing and (tries or 0) < 3 then
    C_Timer.After(1, function() ns.ShopForCraft(row, crafts, (tries or 0) + 1) end)
    return
  end

  local function fmt(t)
    local parts = {}
    for _, e in ipairs(t) do parts[#parts + 1] = e.qty .. "x " .. (e.name or ItemName(e.id) or ("item " .. e.id)) end
    return table.concat(parts, ", ")
  end
  local head = string.format("%d x %s (mats: %s, total %s)", crafts, product,
    ns.CraftSource and ns.CraftSource() or "cheapest", ns.Money(list.cost))
  if #list.ah == 0 then
    Print(head .. ": nothing to buy on the AH.")
  elseif not (api and api.CreateShoppingList and api.ConvertToSearchString) then
    Print(head .. " - buy on the AH: " .. fmt(list.ah) .. "  (install Auctionator for a shopping list)")
  else
    local name = "Ledger: " .. product
    local ok, err = pcall(function()
      local strings = {}
      for _, e in ipairs(list.ah) do
        if e.name then
          strings[#strings + 1] = api.ConvertToSearchString(ns.CALLER,
            {searchString = e.name, isExact = true, quantity = e.qty})
        end
      end
      api.CreateShoppingList(ns.CALLER, name, strings)
    end)
    if not ok then
      Print("couldn't make the Auctionator list (" .. tostring(err) .. "). Buy on the AH: " .. fmt(list.ah))
    else
      Print(head .. " - shopping list \"" .. name .. "\": " .. fmt(list.ah))
      local p = {name = name, t = Now()}
      if ahOpen then TryOpenShop(p)
      else
        pendingShop = p
        Print("open the auction house and Ledger will open it in Auctionator's Shopping tab.")
      end
    end
  end
  if #list.vendor > 0 then Print("  from a vendor: " .. fmt(list.vendor)) end
  if #list.unpriced > 0 then Print("  no price known (not on the list): " .. fmt(list.unpriced)) end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

local f = CreateFrame("Frame")
for _, e in ipairs({"AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "COMMODITY_SEARCH_RESULTS_UPDATED",
  "ITEM_SEARCH_RESULTS_UPDATED", "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT", "ITEM_KEY_ITEM_INFO_RECEIVED"}) do
  pcall(f.RegisterEvent, f, e)
end
f:SetScript("OnEvent", function(_, event, arg)
  if not ns.db then return end
  if event == "AUCTION_HOUSE_SHOW" then
    ahOpen = true
    if ns.RefreshUI then ns.RefreshUI() end
    -- a shopping list made while the AH was closed (within 30 minutes)
    if pendingShop then
      local p = pendingShop
      pendingShop = nil
      if Now() - p.t < 1800 then C_Timer.After(1, function() if ahOpen then TryOpenShop(p) end end) end
    end
    -- an item clicked while the AH was closed: show it once the AH window is up
    if pendingShow then
      local p = pendingShow
      C_Timer.After(0.5, function()
        if pendingShow ~= p or not ahOpen then return end
        local done, err = TryShow(p)
        if done then pendingShow = nil; if err then Print("couldn't open that item in the AH: " .. err) end end
      end)
    end
  elseif event == "ITEM_KEY_ITEM_INFO_RECEIVED" then
    if pendingShow and ahOpen and arg == pendingShow.id then
      local p = pendingShow
      local done, err = TryShow(p)
      if done then pendingShow = nil; if err then Print("couldn't open that item in the AH: " .. err) end end
    end
  elseif event == "AUCTION_HOUSE_CLOSED" then
    ahOpen = false
    if run then Finish("AH closed") elseif ns.RefreshUI then ns.RefreshUI() end
  elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT" then
    sent = sent + 1
  elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    local id = arg
    if type(id) == "number" then
      local units, full = ReadCommodity(id)
      ns.RecordLive(id, units, full)
      if run and run.current and run.current.id == id then Got(run.current) end
    end
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
    local key = arg
    local id = type(key) == "table" and key.itemID
    -- plain items only (gear with a level/suffix is a different auction per variant)
    if id and (key.itemSuffix or 0) == 0 then
      local units, full = ReadItem(key)
      ns.RecordLive(id, units, full)
      if run and run.current and run.current.id == id then Got(run.current) end
    end
  end
end)

-- Someone else's AH query: leave the AH to them for a few seconds.
if hooksecurefunc and C_AuctionHouse then
  for _, fn in ipairs({"SendBrowseQuery", "RequestMoreBrowseResults", "SendSearchQuery", "SendSellSearchQuery",
    "SearchForFavorites", "ReplicateItems"}) do
    if C_AuctionHouse[fn] then
      pcall(hooksecurefunc, C_AuctionHouse, fn, function() if not ours then lastForeign = Now() end end)
    end
  end
end
