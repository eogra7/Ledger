-- Ledger: read-only auction house portfolio tracker for WoW: Forever.
-- This addon never buys, sells, posts, cancels or mails anything. It only
-- reads mail invoices, bag/bank/mail contents and Auctionator's price API,
-- and observes (post-hooks) commodity purchases you make yourself.

local addonName, ns = ...
Ledger = ns -- global handle for /dump debugging

ns.DB_VERSION = 1
ns.CALLER = "Ledger"
ns.AH_CUT = 0.05
ns.TARGET_GAIN = 0.15
ns.MAX_SHARE = 0.25
ns.DEFAULT_CATEGORY = "Other"

local PRICE_DAYS = 21
local MAIL_LIFETIME = 30 * 24 * 60 * 60
local MATCH_TOLERANCE = 30 * 60      -- seconds of slack when re-identifying a mail
local CLICK_KEEP = 7 * 24 * 60 * 60  -- keep observed purchase clicks for a week

-- New installs start with an empty portfolio (v0.9.1). Before that, every
-- install was given the author's own starting positions as "seed" trades;
-- installs created after the author's own (seeded after SEED_CUTOFF) have
-- those removed once at login, see RemoveStraySeeds.
local SEED_CUTOFF = 1794200000 -- 2026-11-09

-- Categories for items that are not in the seed list but are known.
local KNOWN_CATEGORIES = {
  [7912] = "Metals", -- Solid Stone
}

local floor, abs, min = math.floor, math.abs, math.min

local function Round(x) return floor(x + 0.5) end

function ns.Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Ledger|r: " .. tostring(msg))
end
local Print = ns.Print

function ns.Money(c)
  if type(c) ~= "number" then return "-" end
  local neg = c < 0
  c = Round(abs(c))
  local g, s, cp = floor(c / 10000), floor(c / 100) % 100, c % 100
  local out
  if g > 0 then
    out = string.format("%dg%02ds%02d", g, s, cp)
  elseif s > 0 then
    out = string.format("%ds%02d", s, cp)
  else
    out = string.format("%dc", cp)
  end
  return neg and ("-" .. out) or out
end

------------------------------------------------------------------------
-- Database
------------------------------------------------------------------------

local function InitDB()
  if type(LedgerDB) ~= "table" then LedgerDB = {} end
  local db = LedgerDB
  db.version   = db.version or ns.DB_VERSION
  db.positions = db.positions or {}
  db.trades    = db.trades or {}
  db.prices    = db.prices or {}
  db.latest    = db.latest or {}
  db.holdings  = db.holdings or {}
  db.invoices  = db.invoices or {}
  db.clicks    = db.clicks or {}
  db.realized  = db.realized or 0
  db.ui        = db.ui or {}
  db.settings  = db.settings or {}
  db.excluded  = db.excluded or {}   -- [itemID] = true: tracked but left out of the portfolio
  db.used      = db.used or {}       -- [reason] = copper of cost used up (e.g. Engineering)
  db.loans     = db.loans or {}      -- v0.5: gold borrowed from other players (see ns.AddLoan)
  db.loanFees  = db.loanFees or 0    -- v0.5: total fees paid on repaid loans, copper

  -- when tracking started: purchases clicked before this are baseline
  if not db.seeded then db.seeded = time() end
  -- v0.10: a profession window with no name was once recorded as profession ""
  if db.recipeProfs then db.recipeProfs[""] = nil end
  for id, r in pairs(db.recipes or {}) do
    if type(r) == "table" and r.prof == "" then db.recipes[id] = nil end
  end
  ns.db = db
  ns.RemoveStraySeeds()
end

-- v0.9.1: take the author's starting positions back out of installs that were
-- given them (seeded after SEED_CUTOFF). Each "seed" trade's qty and cost come
-- off its position; a position left empty with no other trades is dropped.
function ns.RemoveStraySeeds()
  local db = ns.db
  if not db or db.unseeded or (db.seeded or 0) < SEED_CUTOFF then return end
  local kept, removed, other = {}, 0, {}
  for _, tr in ipairs(db.trades) do
    if tr.type == "seed" then
      local p = tr.itemID and db.positions[tr.itemID]
      if p then
        p.qty = math.max(0, (p.qty or 0) - (tr.qty or 0))
        p.cost = math.max(0, (p.cost or 0) - (tr.gross or 0))
        if p.qty == 0 then p.cost = 0 end
      end
      removed = removed + 1
    else
      kept[#kept + 1] = tr
      if tr.itemID then other[tr.itemID] = true end
    end
  end
  db.trades = kept
  if removed > 0 then
    for id, p in pairs(db.positions) do
      if (p.qty or 0) == 0 and (p.realized or 0) == 0 and not other[id] then db.positions[id] = nil end
    end
    Print(removed .. " placeholder positions from an earlier version removed from your portfolio.")
  end
  db.unseeded = time()
end

-- Item details. The client returns nothing for an item it hasn't loaded yet
-- and fetches it from the server; GET_ITEM_INFO_RECEIVED (see Events) then
-- redraws the window, so names and vendor prices fill in on their own.
local waitingFor = {}   -- [itemID] = true: asked the client for it, not loaded yet
local cantLoad = {}     -- [itemID] = true: the client said it can't load this item

-- name, link, sellPrice (copper), full. full = false when only the name is known
-- (no link or sell price yet); all nil when nothing is loaded.
function ns.ItemInfo(itemID)
  itemID = tonumber(itemID)
  if not itemID then return nil end
  -- C_Item first: on some clients the global GetItemInfo returns nothing even
  -- for items that are loaded (PR #3)
  for _, getInfo in ipairs({C_Item and C_Item.GetItemInfo or false, GetItemInfo or false}) do
    if getInfo then
      local ok, name, link, _, _, _, _, _, _, _, _, sell = pcall(getInfo, itemID)
      if ok and name then
        waitingFor[itemID] = nil
        return name, link, sell, true
      end
    end
  end
  if not cantLoad[itemID] and C_Item and C_Item.RequestLoadItemDataByID then
    waitingFor[itemID] = true
    pcall(C_Item.RequestLoadItemDataByID, itemID)
  end
  if C_Item and C_Item.GetItemNameByID then
    local ok, name = pcall(C_Item.GetItemNameByID, itemID)
    if ok and name then return name, nil, nil, false end
  end
  return nil
end

function ns.ItemName(itemID) return (ns.ItemInfo(itemID)) end

-- GET_ITEM_INFO_RECEIVED: true when the window should redraw for this item.
function ns.ItemInfoReceived(itemID, success)
  itemID = tonumber(itemID)
  if not (itemID and waitingFor[itemID]) then return false end
  waitingFor[itemID] = nil
  if success == false then cantLoad[itemID] = true; return false end
  return true
end

local function GetItemNameSafe(itemID) return ns.ItemName(itemID) end

local function ItemIDFromLink(link)
  if type(link) ~= "string" then return nil end
  local id = link:match("item:(%d+)")
  return id and tonumber(id) or nil
end

local function ItemIDFromName(name)
  if type(name) ~= "string" or name == "" then return nil end
  for id, p in pairs(ns.db.positions) do
    if p.name == name then return id end
  end
  local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if getInstant then
    local ok, id = pcall(getInstant, name)
    if ok and type(id) == "number" then return id end
  end
  return nil
end

local function EnsurePosition(itemID, name)
  local p = ns.db.positions[itemID]
  if not p then
    p = {name = name or GetItemNameSafe(itemID) or ("item:" .. itemID),
         category = KNOWN_CATEGORIES[itemID] or ns.DEFAULT_CATEGORY, qty = 0, cost = 0, realized = 0}
    ns.db.positions[itemID] = p
  elseif name and (p.name == nil or p.name:find("^item:")) then
    p.name = name
  end
  return p
end

-- Average-cost method. Returns basis removed (copper).
local function RemoveFromPosition(p, qty)
  if p.qty <= 0 or qty <= 0 then return 0 end
  local covered = min(qty, p.qty)
  local basis
  if covered >= p.qty then
    basis = p.cost
  else
    basis = Round(p.cost * covered / p.qty)
  end
  p.qty = p.qty - covered
  p.cost = p.cost - basis
  if p.qty <= 0 then p.qty = 0; p.cost = 0 end
  return basis
end

------------------------------------------------------------------------
-- Observed purchase clicks (audit / price cross-check only; never trades)
------------------------------------------------------------------------

local pendingBuy

local function PruneClicks()
  local cutoff = time() - CLICK_KEEP
  local keep = {}
  for _, c in ipairs(ns.db.clicks) do
    if (c.t or 0) >= cutoff then table.insert(keep, c) end
  end
  ns.db.clicks = keep
end

local function FindClick(itemID, qty)
  local now = time()
  for _, c in ipairs(ns.db.clicks) do
    if not c.matched and c.itemID == itemID and c.qty == qty
       and c.t and now - c.t < 24 * 3600 then
      return c
    end
  end
  return nil
end

-- Find an unmatched click made after seeding that explains a buyer invoice
-- (same qty and total, and same item name when the click's name is known).
local function MatchClickForInvoice(inv, qty)
  local seeded = ns.db.seeded or 0
  local total = tonumber(inv[4])
  if not total or not qty then return nil end
  for _, c in ipairs(ns.db.clicks) do
    if not c.matched and (c.t or 0) >= seeded and c.qty == qty and c.total == total then
      local cname = c.itemID and GetItemNameSafe(c.itemID)
      if cname == nil or cname == inv[2] then return c end
    end
  end
  return nil
end

local function HookPurchases()
  if not (C_AuctionHouse and hooksecurefunc) then return end
  if C_AuctionHouse.StartCommoditiesPurchase then
    hooksecurefunc(C_AuctionHouse, "StartCommoditiesPurchase", function(itemID, qty)
      pendingBuy = {itemID = itemID, qty = qty, t = time()}
    end)
  end
  if C_AuctionHouse.ConfirmCommoditiesPurchase then
    hooksecurefunc(C_AuctionHouse, "ConfirmCommoditiesPurchase", function(itemID, qty)
      if pendingBuy and pendingBuy.itemID == itemID then
        pendingBuy.qty = qty or pendingBuy.qty
        pendingBuy.confirmed = true
      end
    end)
  end
end

------------------------------------------------------------------------
-- Mail invoices (the source of truth for trades)
------------------------------------------------------------------------

local function Signature(inv)
  -- playerName is deliberately excluded: it can be nil on the first read and
  -- fill in later, which would make the same mail look new.
  return table.concat({
    tostring(inv[1]), tostring(inv[2]), tostring(inv[4]), tostring(inv[5]),
    tostring(inv[6]), tostring(inv[7]), tostring(inv[10]), tostring(inv[11]),
  }, "|")
end

local function RawCopy(t, n)
  local out = {}
  for i = 1, n do
    local v = t[i]
    if v == nil then v = false end
    out[i] = v
  end
  return out
end

local function InvoiceCount(inv)
  -- Journalator (same author as Auctionator, maintained for this client)
  -- reads the count from return #11; older clients put it at #10.
  local c = inv[11]
  if type(c) == "number" and c >= 1 then return c, 11 end
  c = inv[10]
  if type(c) == "number" and c >= 1 then return c, 10 end
  return nil, nil
end

local function RecordBuy(mail, key, matchedClick)
  local inv = mail.inv
  local itemID = mail.attachID or ItemIDFromName(inv[2]) or (matchedClick and matchedClick.itemID)
  local qty = mail.attachCount or InvoiceCount(inv) or 1
  local gross = tonumber(inv[4]) or 0
  local trade = {
    t = time(), type = "buy", itemID = itemID, name = inv[2], qty = qty,
    gross = gross, cut = 0, deposit = 0, invoiceKey = key,
    seller = inv[3] or nil, mailT = mail.expiry and (mail.expiry - MAIL_LIFETIME) or nil,
    raw = RawCopy(inv, 11),
  }
  if itemID then
    local click = matchedClick or FindClick(itemID, qty)
    if click then
      click.matched = true
      trade.clickTotal = click.total
      -- Guard against the doubled values seen in Journalator's logs.
      if click.total and click.total > 0 and gross > 0
         and abs(gross - 2 * click.total) <= 0.03 * gross then
        trade.grossRaw = gross
        trade.gross = click.total
        trade.fixed = "click"
        gross = click.total
      end
    end
  end
  trade.unit = qty > 0 and Round(gross / qty) or gross

  if itemID then
    local p = EnsurePosition(itemID, inv[2])
    p.qty = p.qty + qty
    p.cost = p.cost + gross
  else
    trade.unresolved = true
    Print("bought " .. tostring(inv[2]) .. " but could not resolve its item ID; position not updated.")
  end
  table.insert(ns.db.trades, trade)
  Print(string.format("recorded buy: %dx %s for %s", qty, tostring(inv[2]), ns.Money(gross)))
  return trade
end

local function RecordSell(mail, key)
  local inv = mail.inv
  local itemID = ItemIDFromName(inv[2])
  local qty, countIdx = InvoiceCount(inv)
  local deposit = tonumber(inv[6]) or 0
  local cut = tonumber(inv[7]) or 0
  local bid = tonumber(inv[4]) or 0
  local gross, net = bid, bid - cut + deposit
  local trade = {
    t = time(), type = "sell", itemID = itemID, name = inv[2],
    cut = cut, deposit = deposit, invoiceKey = key,
    buyer = inv[3] or nil, mailT = mail.expiry - MAIL_LIFETIME,
    raw = RawCopy(inv, 11),
  }
  -- The money attached to the mail is what actually arrives; derive gross
  -- from it so a doubled "bid" value cannot inflate P/L.
  if mail.money and mail.money > 0 then
    net = mail.money
    local derived = net + cut - deposit
    if derived ~= bid then
      trade.grossRaw = bid
      trade.fixed = "money"
      gross = derived
    end
  end
  if not qty then
    qty = 1
    trade.qtyGuess = true
  end
  trade.qty, trade.gross, trade.net = qty, gross, net
  trade.unit = Round(gross / qty)
  trade.countIdx = countIdx

  local p = itemID and ns.db.positions[itemID]
  if p then
    local basis = RemoveFromPosition(p, qty)
    local realized = net - basis
    p.realized = (p.realized or 0) + realized
    ns.db.realized = (ns.db.realized or 0) + realized
    trade.basis, trade.realized = basis, realized
    Print(string.format("recorded sale: %dx %s, net %s, realized %s",
      qty, tostring(inv[2]), ns.Money(net), ns.Money(realized)))
  else
    trade.untracked = true
    Print(string.format("recorded sale of untracked %dx %s, net %s",
      qty, tostring(inv[2]), ns.Money(net)))
  end
  table.insert(ns.db.trades, trade)
end

function ns.ScanInbox()
  local db = ns.db
  if not db or not GetInboxNumItems then return end
  local shown, total = GetInboxNumItems()
  shown = shown or 0
  local complete = (total == nil) or (total <= shown)
  local loading = false
  local now = time()
  local current = {} -- sig -> list of mail records
  local mailHold = {}
  local maxAttach = ATTACHMENTS_MAX_RECEIVE or 16

  for i = 1, shown do
    local _, _, _, subject, money, _, daysLeft, hasItem = GetInboxHeaderInfo(i)
    if subject == nil or subject == RETRIEVING_DATA or daysLeft == nil then
      complete = false
      loading = true
    else
      local attachID, attachCount
      if hasItem then
        for j = 1, maxAttach do
          local _, itemID, _, count = GetInboxItem(i, j)
          if not itemID and GetInboxItemLink then
            itemID = ItemIDFromLink(GetInboxItemLink(i, j))
          end
          if itemID and count then
            mailHold[itemID] = (mailHold[itemID] or 0) + count
            if not attachID then
              attachID, attachCount = itemID, count
            elseif itemID == attachID then
              attachCount = attachCount + count
            end
          end
        end
      end
      local inv = {GetInboxInvoiceInfo(i)}
      local itype = inv[1]
      if (itype == "buyer" or itype == "seller") and inv[2] then
        local sig = Signature(inv)
        current[sig] = current[sig] or {}
        table.insert(current[sig], {
          inv = inv, expiry = floor(now + daysLeft * 86400), money = money,
          attachID = attachID, attachCount = attachCount,
        })
      elseif itype and inv[2] == nil then
        complete = false -- invoice not loaded yet
        loading = true
      end
    end
  end

  -- Match current mails against what we have already recorded.
  for sig, mails in pairs(current) do
    local recs = db.invoices[sig] or {}
    db.invoices[sig] = recs
    local used = {}
    local pending = {}
    -- 1) same mail: expiry within tolerance
    for _, m in ipairs(mails) do
      local hit
      for ri, r in ipairs(recs) do
        if not used[ri] and not r.gone and abs((r.exp or 0) - m.expiry) <= MATCH_TOLERANCE then
          hit = ri; break
        end
      end
      if hit then used[hit] = true else table.insert(pending, m) end
    end
    -- 2) a recorded mail still present whose expiry estimate shifted
    local fresh = {}
    for _, m in ipairs(pending) do
      local hit
      for ri, r in ipairs(recs) do
        if not used[ri] and not r.gone then hit = ri; break end
      end
      if hit then
        used[hit] = true
        recs[hit].exp = m.expiry
      else
        table.insert(fresh, m)
      end
    end
    -- 3) genuinely new invoices. On the very first scan after install, mails
    -- already sitting in the inbox are baselined instead of recorded, since
    -- the seed cost basis may already include them.
    for _, m in ipairs(fresh) do
      local key = sig .. "|" .. m.expiry
      table.insert(recs, {exp = m.expiry, t = now})
      used[#recs] = true
      local click = (not db.mailBaselined and m.inv[1] == "buyer")
        and MatchClickForInvoice(m.inv, m.attachCount or InvoiceCount(m.inv)) or nil
      if click then
        -- A purchase clicked after Ledger was seeded: a real new buy, not baseline.
        RecordBuy(m, key, click)
      elseif not db.mailBaselined then
        db.skipped = db.skipped or {}
        table.insert(db.skipped, {t = now, invoiceKey = key, raw = RawCopy(m.inv, 11), money = m.money})
        Print("baseline: existing " .. tostring(m.inv[1]) .. " invoice for " .. tostring(m.inv[2])
          .. " not recorded (see LedgerDB.skipped)")
      elseif m.inv[1] == "buyer" then
        RecordBuy(m, key)
      else
        RecordSell(m, key)
      end
    end
    -- 4) recorded mails no longer in the inbox have been taken/deleted
    if complete then
      for ri, r in ipairs(recs) do
        if not used[ri] then r.gone = true end
      end
    end
  end

  if not db.mailBaselined and not loading then db.mailBaselined = now end

  if complete then
    for sig, recs in pairs(db.invoices) do
      if not current[sig] then
        for _, r in ipairs(recs) do r.gone = true end
      end
    end
  end

  -- Prune invoice records whose mail must have expired.
  for sig, recs in pairs(db.invoices) do
    local keep = {}
    for _, r in ipairs(recs) do
      if (r.exp or 0) > now - 86400 then table.insert(keep, r) end
    end
    if #keep > 0 then db.invoices[sig] = keep else db.invoices[sig] = nil end
  end

  -- Holdings in mail (only for complete reads, otherwise keep the last value).
  if complete then
    for id in pairs(db.positions) do
      local h = db.holdings[id] or {bags = 0, bank = 0, mail = 0}
      db.holdings[id] = h
      h.mail = mailHold[id] or 0
      h.mailT = now
      h.t = now
    end
  end
  if ns.RefreshUI then ns.RefreshUI() end
end

-- One-time repair (v0.1.0 bug): invoices that were baselined into `skipped`
-- although an unmatched post-seed click explains them are applied as buys.
local function RepairSkippedBuys()
  local db = ns.db
  db.repairs = db.repairs or {}
  if db.repairs.skippedClicks then return end
  local fixed = 0
  for _, s in ipairs(db.skipped or {}) do
    local raw = s.raw
    if not s.applied and type(raw) == "table" and raw[1] == "buyer" and raw[2] then
      local inv = {}
      for i = 1, 11 do if raw[i] ~= false then inv[i] = raw[i] end end
      local qty = InvoiceCount(inv)
      local click = MatchClickForInvoice(inv, qty)
      if click then
        local expiry = tonumber(type(s.invoiceKey) == "string" and s.invoiceKey:match("|(%d+)$"))
        local trade = RecordBuy({inv = inv, expiry = expiry, attachID = click.itemID, attachCount = qty},
          s.invoiceKey, click)
        if trade then trade.repaired = true end
        s.applied = true
        fixed = fixed + 1
      end
    end
  end
  db.repairs.skippedClicks = time()
  if fixed > 0 then
    Print(string.format("repair: applied %d buy(s) that the first mailbox read had skipped", fixed))
  end
end

------------------------------------------------------------------------
-- Owned auctions (read-only: only reads lists the AH UI already fetched)
------------------------------------------------------------------------

function ns.ReadOwnedAuctions()
  local db = ns.db
  if not db then return end
  local counts, ok = {}, false
  local AH = C_AuctionHouse
  if AH and AH.GetNumOwnedAuctions and AH.GetOwnedAuctionInfo then
    local n = AH.GetNumOwnedAuctions() or 0
    for i = 1, n do
      local info = AH.GetOwnedAuctionInfo(i)
      -- status 0 = active, 1 = sold (awaiting mail); only active ones are still yours
      if info and info.status ~= 1 then
        local id = (info.itemKey and info.itemKey.itemID) or ItemIDFromLink(info.itemLink)
        if id then counts[id] = (counts[id] or 0) + (info.quantity or 1) end
      end
    end
    ok = true
  elseif GetNumAuctionItems and GetAuctionItemInfo then
    local n = GetNumAuctionItems("owner") or 0
    for i = 1, n do
      local _, _, count, _, _, _, _, _, _, _, _, _, _, _, _, saleStatus, itemID = GetAuctionItemInfo("owner", i)
      if itemID and saleStatus ~= 1 then counts[itemID] = (counts[itemID] or 0) + (count or 1) end
    end
    ok = true
  end
  if not ok then return end
  local now = time()
  for id in pairs(db.positions) do
    local h = db.holdings[id] or {bags = 0, bank = 0, mail = 0}
    db.holdings[id] = h
    h.auctions = counts[id] or 0
    h.auctionsT = now
  end
  if ns.RefreshUI then ns.RefreshUI() end
end

------------------------------------------------------------------------
-- Holdings
------------------------------------------------------------------------

local function BagIndexes()
  local list, seen = {}, {}
  local function add(i) if i ~= nil and not seen[i] then seen[i] = true; table.insert(list, i) end end
  local E = Enum and Enum.BagIndex
  if E then
    add(E.Backpack); add(E.Bag_1); add(E.Bag_2); add(E.Bag_3); add(E.Bag_4); add(E.ReagentBag)
  end
  if #list == 0 then
    for i = 0, (NUM_BAG_SLOTS or 4) do add(i) end
  end
  return list
end

local function BankIndexes()
  local list, seen = {}, {}
  local function add(i) if i ~= nil and not seen[i] then seen[i] = true; table.insert(list, i) end end
  local E = Enum and Enum.BagIndex
  if E and E.CharacterBankTab_1 then
    for n = 1, 9 do add(E["CharacterBankTab_" .. n]) end
    add(E.Bank)
  else
    add(BANK_CONTAINER or -1)
    local first = (NUM_BAG_SLOTS or 4) + 1
    for i = first, first + (NUM_BANKBAGSLOTS or 7) - 1 do add(i) end
  end
  return list
end

local function CountContainers(indexes)
  local counts = {}
  if not (C_Container and C_Container.GetContainerNumSlots) then return counts end
  for _, bag in ipairs(indexes) do
    local ok, n = pcall(C_Container.GetContainerNumSlots, bag)
    if ok and type(n) == "number" then
      for slot = 1, n do
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info and info.itemID then
          counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1)
        end
      end
    end
  end
  return counts
end

-- Everything in the given containers: [itemID] = {n = count, bound = true|nil}.
-- Used by the "Bank value" tab, so it covers all items, not just positions.
local function SnapshotContainers(indexes)
  local items = {}
  if not (C_Container and C_Container.GetContainerNumSlots) then return items end
  for _, bag in ipairs(indexes) do
    local ok, n = pcall(C_Container.GetContainerNumSlots, bag)
    if ok and type(n) == "number" then
      for slot = 1, n do
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info and info.itemID then
          local e = items[info.itemID] or {n = 0}
          items[info.itemID] = e
          e.n = e.n + (info.stackCount or 1)
          if info.isBound then e.bound = true end
          -- the slot's link carries the name even before the item data is loaded
          local name = type(info.hyperlink) == "string" and info.hyperlink:match("%[(.-)%]")
          if name and name ~= "" then e.name = name end
        end
      end
    end
  end
  return items
end

ns.bankOpen = false

function ns.CountHoldings()
  local db = ns.db
  if not db then return end
  local now = time()
  local bags = CountContainers(BagIndexes())
  local bank = ns.bankOpen and CountContainers(BankIndexes()) or nil
  -- full contents for the Bank value tab (bank only refreshes while it's open)
  db.bagItems = {t = now, items = SnapshotContainers(BagIndexes())}
  if bank then db.bankItems = {t = now, items = SnapshotContainers(BankIndexes())} end
  for id in pairs(db.positions) do
    local h = db.holdings[id] or {bags = 0, bank = 0, mail = 0}
    db.holdings[id] = h
    h.bags = bags[id] or 0
    if bank then h.bank = bank[id] or 0; h.bankT = now end
    h.t = now
  end
end

------------------------------------------------------------------------
-- Prices (Auctionator API v1)
------------------------------------------------------------------------

local function AuctionatorAPI()
  return Auctionator and Auctionator.API and Auctionator.API.v1 or nil
end

local function AuctionatorPrice(itemID)
  local api = AuctionatorAPI()
  if not (api and api.GetAuctionPriceByItemID) then return nil end
  local ok, price = pcall(api.GetAuctionPriceByItemID, ns.CALLER, itemID)
  if not ok or type(price) ~= "number" or price <= 0 then return nil end
  local age, hasAge = nil, false
  if api.GetAuctionAgeByItemID then
    local ok2, a = pcall(api.GetAuctionAgeByItemID, ns.CALLER, itemID)
    if ok2 then age, hasAge = a, true end
  end
  return price, age, hasAge
end

------------------------------------------------------------------------
-- Prices (AHDB / AuctionDB full scans)
------------------------------------------------------------------------
-- AHDB keeps, per auction house, a string per item:
--   houses[house].items[id] = "ts,min,median,qty ts,min,median,qty ..."  every scan of the recent days
--   houses[house].daily[id] = "ts,min,median,qty,scans ..."              one rollup per older day
-- oldest first, unit buyouts in copper (min/median 0 when only bids), ts = server time.
-- houses[house].scans = { {ts, auctions, items}, ... }. Read only; Ledger never writes to it.

local function AHDBHouse()
  local sv = (AuctionDB and AuctionDB.sv) or AuctionDBForeverSaved
  if type(sv) ~= "table" or type(sv.houses) ~= "table" then return nil end
  local name
  if AuctionDB and AuctionDB.ViewHouse then
    local ok, n = pcall(AuctionDB.ViewHouse, AuctionDB)
    if ok then name = n end
  end
  name = name or sv.lastHouse or (UnitFactionGroup and UnitFactionGroup("player"))
  local h = name and sv.houses[name]
  return type(h) == "table" and h or nil, name
end
ns.AHDBHouse = AHDBHouse

local function AHDBPoint(s)
  local p = {}
  for v in s:gmatch("[^,]+") do p[#p + 1] = tonumber(v) end
  return p
end

local function AHDBDecode(s)
  local list = {}
  if type(s) ~= "string" then return list end
  for ps in s:gmatch("%S+") do list[#list + 1] = AHDBPoint(ps) end
  return list
end

-- Latest {ts, min, median, qty} with a buyout: last scan that saw the item, else its last day.
function ns.AHDBLast(itemID)
  local h = AHDBHouse()
  if not h then return nil end
  for _, s in ipairs({h.items and h.items[itemID], h.daily and h.daily[itemID]}) do
    if type(s) == "string" then
      local list = AHDBDecode(s)
      for i = #list, 1, -1 do
        if (list[i][2] or 0) > 0 then return list[i] end
      end
    end
  end
  return nil
end

-- Every recent scan point {ts, min, median, qty} with a buyout, oldest first.
function ns.AHDBScans(itemID)
  local h = AHDBHouse()
  local out = {}
  if not (h and h.items) then return out end
  for _, p in ipairs(AHDBDecode(h.items[itemID])) do
    if (p[2] or 0) > 0 then out[#out + 1] = p end
  end
  return out
end

-- Time of AHDB's last full scan at this house, and how many it keeps.
function ns.AHDBLastScan()
  local h = AHDBHouse()
  local scans = h and h.scans
  if type(scans) ~= "table" or #scans == 0 then return nil, 0 end
  return scans[#scans][1], #scans
end

function ns.HasAHDB() return AHDBHouse() ~= nil end

local function AHDBPrice(itemID)
  local p = ns.AHDBLast(itemID)
  if not (p and p[1]) then return nil end
  local age = math.max(0, floor((time() - p[1]) / (24 * 60 * 60)))
  return p[2], age, true, p
end

-- Live AH search result (Live.lua) newer than AHDB's last scan of the item and
-- at most LIVE_MAX old: {t, min, median, qty, ...} in LedgerDB.live.items.
local LIVE_MAX = 6 * 60 * 60
function ns.LivePrice(itemID)
  local live = ns.db and ns.db.live
  local l = live and live.items and live.items[itemID]
  if not (l and l.min and l.t) or time() - l.t > LIVE_MAX then return nil end
  return l
end

-- Price source: settings.source = "auto" (default: a live AH search when newer,
-- else AHDB when it has a price at least as fresh as Auctionator's), "ahdb"
-- (live or AHDB) or "auctionator" (only that one).
-- Returns price, age (days), hasAge, source ("live"/"ahdb"/"auctionator"), point {ts, min, median, qty}.
local function GetPrice(itemID)
  local src = ns.db and ns.db.settings and ns.db.settings.source or "auto"
  local ap, aage, ahas
  if src ~= "auctionator" then
    local hp, hage, _, pt = AHDBPrice(itemID)
    local l = ns.LivePrice(itemID)
    if l and (not pt or (pt[1] or 0) <= l.t) then
      return l.min, 0, true, "live", {l.t, l.min, l.median, l.qty}
    end
    if hp and src == "ahdb" then return hp, hage, true, "ahdb", pt end
    if hp then
      ap, aage, ahas = AuctionatorPrice(itemID)
      if not ap or not ahas or aage == nil or hage <= aage then return hp, hage, true, "ahdb", pt end
      return ap, aage, ahas, "auctionator"
    end
    if src == "ahdb" then return nil end
  end
  ap, aage, ahas = AuctionatorPrice(itemID)
  if ap then return ap, aage, ahas, "auctionator" end
  return nil
end
ns.GetPrice = GetPrice

local function AnyPriceSource() return AuctionatorAPI() ~= nil or ns.HasAHDB() end

function ns.SnapPrices()
  local db = ns.db
  if not db then return 0 end
  if not AnyPriceSource() then return 0 end
  local now, day, n = time(), date("%Y-%m-%d"), 0
  for id in pairs(db.positions) do
    local price, age, hasAge, src, pt = GetPrice(id)
    if price then
      db.latest[id] = {price = price, age = age, t = now, src = src,
        median = pt and pt[3] or nil, listed = pt and pt[4] or nil, scanT = pt and pt[1] or nil}
      -- Only write today's history if Auctionator actually saw it today
      -- (age 0); a stale price would otherwise pollute the daily series.
      if (not hasAge) or age == 0 then
        local hist = db.prices[id] or {}
        db.prices[id] = hist
        local last = hist[#hist]
        if last and last.day == day then
          last.min = min(last.min or price, price)
          last.last = price
          last.time = now
        else
          table.insert(hist, {day = day, min = price, last = price, time = now})
        end
        while #hist > PRICE_DAYS do table.remove(hist, 1) end
        n = n + 1
      end
    end
  end
  db.lastSnap = now
  return n
end

local snapQueued = false
function ns.QueueSnap(delay)
  if snapQueued then return end
  snapQueued = true
  C_Timer.After(delay or 2, function()
    snapQueued = false
    ns.SnapPrices()
    ns.CountHoldings()
    if ns.RefreshUI then ns.RefreshUI() end
  end)
end

------------------------------------------------------------------------
-- Vendor sell prices (spot AH listings cheaper than a vendor pays)
------------------------------------------------------------------------
-- Sell prices never change, so each item is looked up once and kept in
-- LedgerDB.vendor[itemID] (copper; 0 = can't be sold to a vendor).
-- Lookups are spread over time so the client isn't flooded with item
-- data requests.

local VENDOR_BATCH, VENDOR_TICK, VENDOR_PASSES = 50, 0.25, 3
local vendorRunning = false

-- Plain item ids Auctionator has prices for (gear "g:" / pet "p:" keys skipped).
local function AuctionatorItemIDs()
  -- Auctionator's scanned items plus AHDB's (both when present, no repeats)
  local d = Auctionator and Auctionator.Database and Auctionator.Database.db
  local ids, seen = {}, {}
  local function add(key)
    local id = type(key) == "number" and key or (type(key) == "string" and key:match("^%d+$") and tonumber(key))
    if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
  end
  if type(d) == "table" then for key in pairs(d) do add(key) end end
  local h = AHDBHouse()
  if h and type(h.items) == "table" then for key in pairs(h.items) do add(key) end end
  return ids
end

------------------------------------------------------------------------
-- Vendor price corrections
------------------------------------------------------------------------
-- The client's item data (GetItemInfo's sell price) is wrong for some items on
-- Forever: Iron Grenade says 5s, vendors pay 1s25. Corrections win over it:
--   1. LedgerDB.vendorFix[itemID] (copper; 0 = vendors won't buy it): learned at
--      the merchant when a sale pays something else, or set with /ledger vendorprice
--   2. KNOWN_VENDOR_FIX below (reported prices)
--   3. AHDB's list of items vendors refuse (sv.unsellable) -> 0
local KNOWN_VENDOR_FIX = {
  [4390] = 125, -- Iron Grenade: item data 5s00, vendors pay 1s25
}

function ns.VendorFix(itemID)
  local db = ns.db
  local v = db and db.vendorFix and db.vendorFix[itemID]
  if v ~= nil then return v, "yours" end
  v = KNOWN_VENDOR_FIX[itemID]
  if v ~= nil then return v, "known" end
  local sv = (AuctionDB and AuctionDB.sv) or AuctionDBForeverSaved
  if type(sv) == "table" and type(sv.unsellable) == "table" and sv.unsellable[itemID] then return 0, "unsellable" end
  return nil
end

-- Write every correction over the vendor price cache (LedgerDB.vendor), which
-- every tab reads. Run at login and whenever a correction changes.
function ns.ApplyVendorFixes()
  local db = ns.db
  if not db then return end
  db.vendor = db.vendor or {}
  for id, v in pairs(KNOWN_VENDOR_FIX) do if not (db.vendorFix and db.vendorFix[id]) then db.vendor[id] = v end end
  for id, v in pairs(db.vendorFix or {}) do db.vendor[id] = v end
  local sv = (AuctionDB and AuctionDB.sv) or AuctionDBForeverSaved
  if type(sv) == "table" and type(sv.unsellable) == "table" then
    for id in pairs(sv.unsellable) do
      if not (db.vendorFix and db.vendorFix[id]) then db.vendor[id] = 0 end
    end
  end
end

-- copper = nil removes your correction (back to the item data).
function ns.SetVendorFix(itemID, copper, quiet)
  local db = ns.db
  if not (db and itemID) then return end
  db.vendorFix = db.vendorFix or {}
  db.vendorFix[itemID] = copper
  if copper == nil then
    db.vendor = db.vendor or {}
    db.vendor[itemID] = nil   -- looked up again from the item data next time
  end
  ns.ApplyVendorFixes()
  if ns.BelowVendor then ns.BelowVendor() end
  if ns.RefreshUI then ns.RefreshUI() end
end

-- Learn at the merchant: right-clicking a bag item sells it. Remember what was
-- sold and the gold before; the next money change (within 2 s, one sale
-- pending) gives the real price per unit. When it differs from what Ledger
-- has, it's saved as a correction.
local pendingSale
if hooksecurefunc and C_Container and C_Container.UseContainerItem then
  pcall(hooksecurefunc, C_Container, "UseContainerItem", function(bag, slot)
    if not (MerchantFrame and MerchantFrame:IsShown() and ns.db and GetMoney) then return end
    if pendingSale and GetTime() - pendingSale.at < 2 then pendingSale.multi = true; return end
    local info = C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
    local id = info and info.itemID or (C_Container.GetContainerItemID and C_Container.GetContainerItemID(bag, slot))
    if not id then return end
    pendingSale = {id = id, count = (info and info.stackCount) or 1, money = GetMoney(), at = GetTime()}
  end)
end

function ns.OnMoneyChanged()
  local s = pendingSale
  pendingSale = nil
  if not (s and not s.multi and GetTime() - s.at < 2 and GetMoney) then return end
  local got = GetMoney() - s.money
  if got <= 0 or s.count <= 0 or got % s.count ~= 0 then return end
  local each = floor(got / s.count)
  local db = ns.db
  local known = db.vendor and db.vendor[s.id]
  if known == nil then known = select(3, ns.ItemInfo(s.id)) end
  if known ~= each then
    ns.SetVendorFix(s.id, each)
    local _, link = ns.ItemInfo(s.id)
    Print(string.format("%s: vendors pay %s each, not %s - vendor price corrected.",
      (type(link) == "string" and link) or ("item " .. s.id), ns.Money(each), ns.Money(tonumber(known))))
  end
end

-- nil = item data not loaded yet (a load is requested; try again later).
local function SellPrice(itemID)
  local fix = ns.VendorFix(itemID)
  if fix ~= nil then return fix end
  local _, _, sell, full = ns.ItemInfo(itemID)
  if full then return tonumber(sell) or 0 end
  return nil
end
ns.SellPrice = SellPrice

function ns.VendorRunning() return vendorRunning end

-- Value of everything in the bank (and optionally bags), from the last
-- snapshot. Each item is valued at the Auctionator price when it can be
-- sold there (not soulbound, has a price), else at the vendor price.
-- Returns rows plus totals; rows carry:
--   id, n, ah (each), vendor (each), each, value, how ("ah"|"vendor"|nil), bound, age
function ns.BankValue(includeBags)
  local db = ns.db
  local out = {rows = {}, total = 0, ahTotal = 0, vendorTotal = 0, unpriced = 0, loading = 0}
  if not db then return out end
  local bank = db.bankItems
  out.bankT = bank and bank.t
  out.bagT = db.bagItems and db.bagItems.t
  local merged = {}
  local function add(src)
    for id, e in pairs((src and src.items) or {}) do
      local m = merged[id] or {n = 0}
      merged[id] = m
      m.n = m.n + (e.n or 0)
      if e.bound then m.bound = true end
      m.name = m.name or e.name
    end
  end
  add(bank)
  if includeBags then add(db.bagItems) end
  db.vendor = db.vendor or {}
  for id, e in pairs(merged) do
    -- name: the client's, else the one saved from the bank slot's link
    local r = {id = id, n = e.n, bound = e.bound, name = GetItemNameSafe(id) or e.name}
    local vend = db.vendor[id]
    if vend == nil then
      vend = SellPrice(id)
      if vend then db.vendor[id] = vend else out.loading = out.loading + 1 end
    end
    r.vendor = vend
    if not e.bound then
      local price, age = GetPrice(id)
      r.ah, r.age = price, age
    end
    if r.ah then
      r.each, r.how = r.ah, "ah"
    elseif vend and vend > 0 then
      r.each, r.how = vend, "vendor"
    end
    r.value = r.each and r.each * r.n or nil
    if r.value then
      out.total = out.total + r.value
      if r.how == "ah" then out.ahTotal = out.ahTotal + r.value else out.vendorTotal = out.vendorTotal + r.value end
    else
      out.unpriced = out.unpriced + 1
    end
    out.rows[#out.rows + 1] = r
  end
  return out
end

function ns.ScanVendorPrices(onDone)
  local db = ns.db
  if not db or vendorRunning then return false end
  local ids = AuctionatorItemIDs()
  if #ids == 0 then return false end
  db.vendor = db.vendor or {}
  local todo = {}
  for _, id in ipairs(ids) do
    if db.vendor[id] == nil then todo[#todo + 1] = id end
  end
  vendorRunning = true
  local i, pass, retry = 1, 1, {}
  local function step()
    local stop = min(i + VENDOR_BATCH - 1, #todo)
    for k = i, stop do
      local id = todo[k]
      local sell = SellPrice(id)
      if sell then db.vendor[id] = sell else retry[#retry + 1] = id end
    end
    i = stop + 1
    if i <= #todo then C_Timer.After(VENDOR_TICK, step); return end
    if #retry > 0 and pass < VENDOR_PASSES then
      -- give the client a moment to load the items it was asked for
      todo, retry, i, pass = retry, {}, 1, pass + 1
      C_Timer.After(2, step)
      return
    end
    vendorRunning = false
    db.vendorScan = time()
    if onDone then onDone(#retry) end
  end
  step()
  return true
end

------------------------------------------------------------------------
-- Listings by price (from AHDB's full scans)
------------------------------------------------------------------------
-- After each full scan AHDB hands its auctions to listening add-ons
-- (AuctionDB:Listen("SCAN_DATA"), e.byItem[id].units = {{unitBuyout, count}, ...}).
-- Ledger keeps, per item, its cheapest price levels:
--   LedgerDB.listings = {t = scan time, items = {[id] = "price,auctions,units price,auctions,units ..."}}
-- cheapest first, unit buyouts in copper. Levels are kept while they're under
-- the vendor price (when known), else only the first few. Read only.

local LEVELS_MIN, LEVELS_MAX = 3, 25
-- keep levels until this many units are covered too, so the Crafting tab can
-- price buying a batch / selling past a few cheap stragglers (v0.8.3)
local LEVELS_UNITS = 200

function ns.RecordListings(e)
  local db = ns.db
  if not (db and type(e) == "table" and type(e.byItem) == "table") then return 0 end
  local items, n = {}, 0
  for id, t in pairs(e.byItem) do
    local src = t.units
    if type(src) == "table" and #src > 0 then
      local units = {}
      for i, u in ipairs(src) do units[i] = u end -- sort a copy; AHDB's data stays as it was
      table.sort(units, function(a, b) return a[1] < b[1] end)
      local vend = db.vendor and db.vendor[id] or 0
      local parts, last, cum = {}, nil, 0
      for _, u in ipairs(units) do
        local price, count = u[1], u[2] or 1
        if last and last[1] == price then
          last[2], last[3] = last[2] + 1, last[3] + count
          cum = cum + count
        else
          if #parts >= LEVELS_MAX or (#parts >= LEVELS_MIN and price >= vend and cum >= LEVELS_UNITS) then break end
          cum = cum + count
          last = {price, 1, count}
          parts[#parts + 1] = last
        end
      end
      for i, l in ipairs(parts) do parts[i] = l[1] .. "," .. l[2] .. "," .. l[3] end
      items[id] = table.concat(parts, " ")
      n = n + 1
    end
  end
  db.listings = {t = time(), items = items}
  return n
end

-- Price levels {{price, auctions, units}, ...} cheapest first, or nil.
function ns.ListingLevels(itemID)
  local l = ns.db and ns.db.listings
  local s = l and l.items and l.items[itemID]
  -- a live search newer than the last full scan wins
  local live = ns.LivePrice and ns.LivePrice(itemID)
  if live and live.levels and (not s or live.t >= (l.t or 0)) then s = live.levels end
  if type(s) ~= "string" then return nil end
  local out = {}
  for p, a, u in s:gmatch("(%d+),(%d+),(%d+)") do out[#out + 1] = {tonumber(p), tonumber(a), tonumber(u)} end
  return #out > 0 and out or nil
end

-- Hook AHDB's scan hand-off (AHDB loads first: OptionalDeps).
if AuctionDB and AuctionDB.Listen then
  pcall(AuctionDB.Listen, AuctionDB, "SCAN_DATA", function(_, e)
    if ns.db then
      ns.RecordListings(e)
      if ns.RefreshUI then ns.RefreshUI() end
    end
  end)
end

-- Items whose current price (seen today or yesterday) is below what a vendor
-- pays. Saved to LedgerDB.belowVendor; best gain first. With AHDB listing
-- levels, each also gets: atMin/atMinUnits (auctions and units at the lowest
-- price) and under/underCost/underGain (units under vendor price, what buying
-- them all costs, and what a vendor would pay on top).
function ns.BelowVendor()
  local out, db = {}, ns.db
  if not (db and db.vendor) then return out end
  for id, sell in pairs(db.vendor) do
    if sell > 0 then
      local price, age, hasAge = GetPrice(id)
      if price and price < sell and (not hasAge or (age or 99) <= 1) then
        local r = {id = id, name = GetItemNameSafe(id) or ("item " .. id),
          ah = price, vendor = sell, gain = sell - price, age = age}
        local levels = ns.ListingLevels(id)
        if levels then
          if levels[1][1] == price then r.atMin, r.atMinUnits = levels[1][2], levels[1][3] end
          local units, cost = 0, 0
          for _, l in ipairs(levels) do
            if l[1] < sell then units, cost = units + l[3], cost + l[1] * l[3] end
          end
          if units > 0 then r.under, r.underCost, r.underGain = units, cost, sell * units - cost end
        end
        out[#out + 1] = r
      end
    end
  end
  table.sort(out, function(a, b) return a.gain > b.gain end)
  db.belowVendor = {t = time(), items = out}
  return out
end

-- Clickable item link when the client has the item loaded, else its name.
local function ItemLabel(id)
  local name, link = ns.ItemInfo(id)
  return link or name
end

-- quiet: print nothing when the list is empty (used after each scan).
-- Items whose names aren't loaded yet are requested and the report is
-- retried once a second later, so lines don't show as "item 7608".
local function ReportBelowVendor(limit, quiet, retried)
  local list = ns.BelowVendor()
  if #list == 0 then
    if not quiet then Print("no items listed below vendor price in the latest scan.") end
    return
  end
  limit = min(limit or 10, #list)
  local missing = false
  for k = 1, limit do
    if not ItemLabel(list[k].id) then
      missing = true
      if C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, list[k].id)
      end
    end
  end
  if missing and not retried then
    C_Timer.After(1, function() ReportBelowVendor(limit, quiet, true) end)
    return
  end
  Print(string.format("%d items listed below vendor price (gain per item = vendor - AH):", #list))
  for k = 1, limit do
    local r = list[k]
    local label = ItemLabel(r.id) or ("item " .. r.id)
    r.name = label:match("%[(.-)%]") or label -- keep the saved name plain text
    local extra = ""
    if r.atMin then
      extra = string.format(" - %d listing%s (%d) at that price", r.atMin, r.atMin == 1 and "" or "s", r.atMinUnits)
      if r.under and r.under > r.atMinUnits then
        extra = extra .. string.format(", %d under vendor for +%s in all", r.under, ns.Money(r.underGain))
      elseif r.underGain then
        extra = extra .. string.format(", +%s in all", ns.Money(r.underGain))
      end
    end
    Print(string.format("  %s: AH %s, vendor %s, +%s%s", label, ns.Money(r.ah), ns.Money(r.vendor), ns.Money(r.gain), extra))
  end
  Print("Counts are from the last full AHDB scan; some may have sold since.")
end

------------------------------------------------------------------------
-- Portfolio math (shared by UI and chat)
------------------------------------------------------------------------

-- Excluded items keep their position and trades (so nothing is lost and
-- they can be brought back) but are left out of every total, chart and rule.
function ns.SetExcluded(itemID, excluded)
  local db = ns.db
  if not (db and itemID and db.positions[itemID]) then return false end
  db.excluded[itemID] = excluded and true or nil
  if ns.RefreshUI then ns.RefreshUI() end
  return true
end

-- Items used up without a sale (crafting, quest turn-ins). They leave the
-- position at average cost, so realized P/L is unchanged; the cost is added
-- to LedgerDB.used[reason] (e.g. used.Engineering) as a spending total.
function ns.Consume(itemID, qty, reason)
  local db = ns.db
  local p = db and db.positions[itemID]
  if not (p and qty and qty > 0 and (p.qty or 0) > 0) then return false end
  if reason == "" then reason = nil end
  local removed = min(qty, p.qty)
  local basis = RemoveFromPosition(p, qty)
  table.insert(db.trades, {t = time(), type = "consume", itemID = itemID, name = p.name,
    qty = removed, basis = basis, reason = reason, gross = 0, cut = 0, deposit = 0})
  if reason then db.used[reason] = (db.used[reason] or 0) + basis end
  Print(string.format("used %dx %s%s (cost %s)", removed, p.name, reason and (" for " .. reason) or "",
    ns.Money(basis)))
  if ns.RefreshUI then ns.RefreshUI() end
  return true
end

------------------------------------------------------------------------
-- Loans (gold borrowed from other players)
------------------------------------------------------------------------
-- Ledger can't see gold handed over in a trade window, so loans are entered
-- by hand. The whole amount owed (principal + fee) counts as a debt from the
-- day the loan is taken: it comes off cash and total wealth straight away.

-- "4g", "4g50s", "1.5g", "75s", "20c", "4g 50s"; a bare number means gold.
function ns.ParseMoney(s)
  if type(s) ~= "string" then return nil end
  s = s:lower():gsub("%s+", "")
  if s == "" then return nil end
  local n = tonumber(s)
  if n then return n >= 0 and Round(n * 10000) or nil end
  local total, rest = 0, s
  for _, u in ipairs({{"g", 10000}, {"s", 100}, {"c", 1}}) do
    local num, after = rest:match("^([%d%.]+)" .. u[1] .. "(.*)$")
    if num then
      if not tonumber(num) then return nil end
      total, rest = total + tonumber(num) * u[2], after
    end
  end
  if rest ~= "" then return nil end
  return Round(total)
end

local DAY = 24 * 60 * 60

function ns.OpenLoans()
  local out = {}
  for _, l in ipairs(ns.db and ns.db.loans or {}) do
    if not l.repaid then table.insert(out, l) end
  end
  table.sort(out, function(a, b) return (a.due or 0) < (b.due or 0) end)
  return out
end

function ns.LoanOwed(l) return (l.principal or 0) + (l.fee or 0) - (l.paid or 0) end

function ns.DebtTotal()
  local total = 0
  for _, l in ipairs(ns.OpenLoans()) do total = total + ns.LoanOwed(l) end
  return total
end

-- "due in 3d", "due today", "2d overdue"
function ns.DueText(l)
  if not l.due then return "no due date" end
  local today = date("%Y-%m-%d")
  local dueDay = date("%Y-%m-%d", l.due)
  if dueDay == today then return "due today" end
  local days = math.ceil((l.due - time()) / DAY)
  if l.due < time() then return math.max(1, -days) .. "d overdue" end
  return "due in " .. math.max(1, days) .. "d (" .. date("%b %d", l.due) .. ")"
end

function ns.AddLoan(who, principal, fee, days)
  local db = ns.db
  local now = time()
  local maxId = 0
  for _, l in ipairs(db.loans) do if (l.id or 0) > maxId then maxId = l.id end end
  local l = {id = maxId + 1, who = who, principal = principal, fee = fee or 0, paid = 0,
    t = now, due = days and (now + days * DAY) or nil}
  table.insert(db.loans, l)
  local rate = principal > 0 and (l.fee / principal) or 0
  Print(string.format("loan #%d from %s: %s, fee %s (%.0f%%), you owe %s, %s", l.id, who,
    ns.Money(principal), ns.Money(l.fee), rate * 100, ns.Money(ns.LoanOwed(l)), ns.DueText(l)))
  if rate > 0 and days and days > 0 then
    Print(string.format("  to come out ahead, the %s needs to earn more than %s (+%.0f%%) by then.",
      ns.Money(principal), ns.Money(l.fee), rate * 100))
  end
  if ns.RefreshUI then ns.RefreshUI() end
  return l
end

-- Find an open loan by id ("#2" or "2") or lender name (oldest due first).
function ns.FindLoan(key)
  if not key or key == "" then
    local open = ns.OpenLoans()
    return #open == 1 and open[1] or nil, #open
  end
  local id = tonumber((key:gsub("^#", "")))
  local lk = key:lower()
  for _, l in ipairs(ns.OpenLoans()) do
    if (id and l.id == id) or (not id and (l.who or ""):lower() == lk) then return l end
  end
  return nil
end

-- Record a repayment (all of what's owed when amount is nil). Fees count as
-- paid in proportion: the principal is paid back first, then the fee.
function ns.RepayLoan(l, amount)
  local owed = ns.LoanOwed(l)
  amount = math.min(amount or owed, owed)
  if amount <= 0 then return false end
  local before = l.paid or 0
  l.paid = before + amount
  local feePaid = math.max(0, l.paid - l.principal) - math.max(0, before - l.principal)
  ns.db.loanFees = (ns.db.loanFees or 0) + feePaid
  if ns.LoanOwed(l) <= 0 then
    l.repaid = time()
    Print(string.format("loan #%d from %s repaid in full (%s total, fee %s).", l.id, l.who,
      ns.Money(l.paid), ns.Money(l.fee)))
  else
    Print(string.format("paid %s to %s; %s still owed, %s.", ns.Money(amount), l.who,
      ns.Money(ns.LoanOwed(l)), ns.DueText(l)))
  end
  if ns.RefreshUI then ns.RefreshUI() end
  return true
end

function ns.ReportLoans(quiet)
  local open = ns.OpenLoans()
  if #open == 0 then
    if not quiet then Print("no open loans.") end
    return
  end
  for _, l in ipairs(open) do
    local overdue = l.due and l.due < time()
    Print(string.format("%sloan #%d: owe %s %s, %s|r", overdue and "|cffff4040" or "", l.id, l.who,
      ns.Money(ns.LoanOwed(l)), ns.DueText(l)))
  end
end

-- Settings are stored as whole percentages in LedgerDB.settings.
ns.SETTING_DEFAULTS = {cash = 10, cap = 25, sell = 15}

function ns.Setting(key)
  local s = ns.db and ns.db.settings
  local v = s and tonumber(s[key])
  if v == nil then v = ns.SETTING_DEFAULTS[key] end
  return v
end

-- Up to the last 7 stored days of mins, and the % change across them.
local function Trend(hist, itemID)
  -- AHDB first: one point per full scan (the last 7), when it has 2 or more
  local src = ns.db.settings.source or "auto"
  if itemID and src ~= "auctionator" then
    local scans = ns.AHDBScans(itemID)
    if #scans >= 2 then
      local spark = {}
      for i = math.max(1, #scans - 6), #scans do
        local p = scans[i]
        table.insert(spark, {day = date("%m-%d %H:%M", p[1]), min = p[2], median = p[3], qty = p[4]})
      end
      local change
      if spark[1].min > 0 then change = (spark[#spark].min - spark[1].min) / spark[1].min end
      return spark, change, "scan"
    end
  end
  if type(hist) ~= "table" or #hist == 0 then return nil, nil end
  local n = #hist
  local spark = {}
  for i = math.max(1, n - 6), n do
    local e = hist[i]
    if type(e) == "table" and type(e.min) == "number" then
      table.insert(spark, {day = e.day, min = e.min})
    end
  end
  local change
  if #spark >= 2 and spark[1].min > 0 then
    change = (spark[#spark].min - spark[1].min) / spark[1].min
  end
  return spark, change, "day"
end

function ns.Compute()
  local db = ns.db
  local cap = ns.Setting("cap") / 100
  local sellGain = ns.Setting("sell") / 100
  local cashTarget = ns.Setting("cash") / 100
  local rows, cats = {}, {}
  local totalCost, totalValue, totalNet, pricedCost = 0, 0, 0, 0
  for id, p in pairs(db.positions) do
    if (p.qty or 0) > 0 and not db.excluded[id] then
      local lp = db.latest[id]
      local price = lp and lp.price or nil
      local h = db.holdings[id]
      local r = {
        itemID = id, name = p.name or ("item:" .. id), category = p.category or ns.DEFAULT_CATEGORY,
        qty = p.qty, cost = p.cost or 0, avg = (p.cost or 0) / p.qty, price = price,
        priceAge = lp and lp.age or nil, priceSrc = lp and lp.src or nil,
        median = lp and lp.median or nil, listed = lp and lp.listed or nil, scanT = lp and lp.scanT or nil,
        auctions = h and h.auctions or 0, holdings = h,
        have = h and ((h.bags or 0) + (h.bank or 0) + (h.mail or 0) + (h.auctions or 0)) or nil,
      }
      -- fewer counted (bags+bank+mail+AH) than recorded, with the bank counted
      -- at least once: probably used up crafting. Only a hint; the user confirms.
      if h and h.bankT and r.have and r.have < p.qty then r.missing = p.qty - r.have end
      r.spark, r.trend, r.sparkKind = Trend(db.prices[id], id)
      local c = cats[r.category] or {value = 0, cost = 0, n = 0}
      cats[r.category] = c
      c.cost = c.cost + r.cost
      c.n = c.n + 1
      if price then
        r.value = price * p.qty
        r.net = r.value * (1 - ns.AH_CUT)
        r.gain = r.net - r.cost
        r.pct = r.cost > 0 and (r.gain / r.cost) or nil
        -- sell signal: price * (1 - cut) >= avg cost * (1 + target)
        r.sell = price * (1 - ns.AH_CUT) >= r.avg * (1 + sellGain)
        totalValue = totalValue + r.value
        totalNet = totalNet + r.net
        pricedCost = pricedCost + r.cost
        c.value = c.value + r.value
      end
      totalCost = totalCost + r.cost
      table.insert(rows, r)
    end
  end

  local largestItem, overCap = nil, 0
  for _, r in ipairs(rows) do
    r.share = (r.value and totalValue > 0) and r.value / totalValue or nil
    r.cap = r.share ~= nil and r.share > cap
    if r.cap then overCap = overCap + 1 end
    if r.share and (not largestItem or r.share > largestItem.share) then largestItem = r end
  end
  local catList = {}
  for name, c in pairs(cats) do
    c.name = name
    c.share = totalValue > 0 and c.value / totalValue or 0
    c.over = c.share > cap
    if c.over then overCap = overCap + 1 end
    table.insert(catList, c)
  end
  table.sort(rows, function(a, b) return (a.value or 0) > (b.value or 0) end)
  table.sort(catList, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    return a.name < b.name
  end)

  -- Loans: what's owed comes off cash (net cash can go negative) and wealth.
  local gross = GetMoney and GetMoney() or 0
  local debt = ns.DebtTotal()
  local cash = gross - debt
  local wealth = cash + totalValue
  local unreal = totalNet - pricedCost
  local cashShare = (wealth > 0 and cash > 0) and cash / wealth or 0

  -- Freshness: last Auctionator scan/search seen by Ledger, else newest
  -- same-day price Ledger stored.
  local priceTime = db.lastScan
  local ahdbT = (db.settings.source or "auto") ~= "auctionator" and ns.AHDBLastScan() or nil
  if ahdbT and (not priceTime or ahdbT > priceTime) then priceTime = ahdbT end
  if not priceTime then
    for _, hist in pairs(db.prices) do
      local e = type(hist) == "table" and hist[#hist]
      if e and e.time and (not priceTime or e.time > priceTime) then priceTime = e.time end
    end
  end

  return {
    rows = rows, cats = catList, totalCost = totalCost, totalValue = totalValue,
    totalNet = totalNet, pricedCost = pricedCost, unreal = unreal,
    unrealPct = pricedCost > 0 and unreal / pricedCost or nil,
    cash = cash, wealth = wealth, cashShare = cashShare, cashOk = cashShare >= cashTarget,
    realized = db.realized or 0, nPositions = #rows, nCats = #catList,
    largestCat = catList[1], largestItem = largestItem, overCap = overCap,
    priceTime = priceTime, cap = cap, sellGain = sellGain, cashTarget = cashTarget,
    used = db.used,
    grossCash = gross, debt = debt, loans = ns.OpenLoans(), loanFees = db.loanFees or 0,
  }
end

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------

local function Help()
  Print("commands:")
  Print("  /ledger - show/hide the portfolio window")
  Print("  /ledger snap - refresh prices (from Auctionator) and holdings now")
  Print("  /ledger cat <itemID> <category> - set an item's category")
  Print("  /ledger use <itemID> <qty> [reason] - used up crafting (default: your main profession), at average cost")
  Print("  /ledger consume <itemID> <qty> [reason] - same, no default reason (e.g. quest turn-in)")
  Print(string.format("  /ledger target cash|cap|sell <percent> - targets (now cash %s%%, cap %s%%, sell +%s%%)",
    tostring(ns.Setting("cash")), tostring(ns.Setting("cap")), tostring(ns.Setting("sell"))))
  Print("  /ledger source auto|ahdb|auctionator - where prices come from (now " .. (ns.db.settings.source or "auto") .. ")")
  Print("  /ledger vendor - list AH items priced below what a vendor pays")
  Print("  /ledger exclude <itemID> - leave an item out of the portfolio (or right-click its row)")
  Print("  /ledger include <itemID> - bring an excluded item back")
  Print("  /ledger excluded - list excluded items")
  Print("  /ledger loan <name> <amount> <fee> [days] - record gold borrowed (e.g. loan Alex 4g 1g 7)")
  Print("  /ledger repay <name|#id> [amount] - record paying a loan back (all of it if no amount)")
  Print("  /ledger loans - list open loans")
  Print("  /ledger vendorprice [<item> <amount>|reset] - correct a wrong vendor price (sales correct it too)")
  Print("  /ledger craft [n] - most profitable crafts from your recipes (open your profession window once)")
  Print("  /ledger craftmode cheapest|ah|craft - reagents: whichever costs less, buy them all, or craft what you can")
  Print("  /ledger anvil [on|off] - off: hide recipes that need an anvil (crafting at the AH)")
  Print("  /ledger craftdepth <buy> [skip] - units used to price reagents (avg of cheapest N) and products (past N)")
  Print("  /ledger craft new [n] - profitable recipes you have not learned yet (visit your trainer to add its list)")
  Print("  /ledger minimap - show/hide the minimap button")
  Print("  /ledger help - this help")
  Print("Ledger is read-only: it never buys, sells, posts, cancels or mails anything.")
end

SLASH_LEDGER1 = "/ledger"
SlashCmdList["LEDGER"] = function(msg)
  if not ns.db then Print("not loaded yet"); return end
  msg = strtrim and strtrim(msg or "") or (msg or "")
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()
  if cmd == "" or cmd == "show" then
    if ns.ToggleUI then ns.ToggleUI() end
  elseif cmd == "snap" then
    if not AnyPriceSource() then Print("neither AHDB nor Auctionator is loaded; prices unavailable.") end
    local n = ns.SnapPrices()
    ns.CountHoldings()
    if ns.RefreshUI then ns.RefreshUI() end
    Print(string.format("snapshot: %d item prices recorded for today%s", n,
      ns.bankOpen and ", bank counted" or ""))
  elseif cmd == "target" then
    local key, val = rest:match("^(%a+)%s+([%d%.]+)%%?$")
    key, val = key and key:lower(), tonumber(val)
    local limits = {cash = {0, 100}, cap = {1, 100}, sell = {0, 1000}}
    if key and limits[key] and val and val >= limits[key][1] and val <= limits[key][2] then
      ns.db.settings[key] = val
      Print(string.format("target %s set to %s%%", key, tostring(val)))
      if ns.RefreshUI then ns.RefreshUI() end
    else
      Print(string.format("usage: /ledger target cash|cap|sell <percent>  (now cash %s%%, cap %s%%, sell +%s%%)",
        tostring(ns.Setting("cash")), tostring(ns.Setting("cap")), tostring(ns.Setting("sell"))))
    end
  elseif cmd == "vendor" then
    if not AnyPriceSource() then Print("neither AHDB nor Auctionator is loaded; prices unavailable."); return end
    if not vendorRunning then Print("checking vendor prices for scanned items...") end
    local started = ns.ScanVendorPrices(function(missing)
      if missing > 0 then Print(string.format("(%d items had no item data yet; run again later)", missing)) end
      ReportBelowVendor(10)
    end)
    if started then
      -- results print when the lookup finishes (at once if prices are cached)
    elseif vendorRunning then
      Print("vendor price lookup already running; results will print when done.")
    else
      Print("no scan data yet - do a full AHDB or Auctionator scan first.")
    end
  elseif cmd == "exclude" or cmd == "include" then
    local id = tonumber(rest:match("^(%d+)$") or "")
    local p = id and ns.db.positions[id]
    if p then
      ns.SetExcluded(id, cmd == "exclude")
      Print(p.name .. (cmd == "exclude" and " excluded from the portfolio." or " is back in the portfolio."))
    else
      Print("usage: /ledger " .. cmd .. " <itemID> (item must be tracked; /ledger excluded lists them)")
    end
  elseif cmd == "excluded" then
    local n = 0
    for id in pairs(ns.db.excluded) do
      local p = ns.db.positions[id]
      Print(string.format("  %d  %s  (qty %d)", id, p and p.name or "?", p and p.qty or 0))
      n = n + 1
    end
    Print(n == 0 and "no excluded items." or "bring one back with /ledger include <itemID>")
  elseif cmd == "minimap" then
    ns.db.ui.minimapHidden = not ns.db.ui.minimapHidden
    if ns.UpdateMinimapButton then ns.UpdateMinimapButton() end
    Print("minimap button " .. (ns.db.ui.minimapHidden and "hidden" or "shown"))
  elseif cmd == "cat" then
    local id, cat = rest:match("^(%d+)%s+(.+)$")
    id = tonumber(id)
    if id and ns.db.positions[id] then
      ns.db.positions[id].category = cat
      Print(ns.db.positions[id].name .. " -> " .. cat)
      if ns.RefreshUI then ns.RefreshUI() end
    else
      Print("usage: /ledger cat <itemID> <category> (item must be tracked)")
    end
  elseif cmd == "consume" or cmd == "use" then
    local id, qty, reason = rest:match("^(%d+)%s+(%d+)%s*(.-)$")
    id, qty = tonumber(id), tonumber(qty)
    if cmd == "use" and (reason == nil or reason == "") then reason = ns.MainCraftProf and ns.MainCraftProf() or "Engineering" end
    if not (id and qty and ns.Consume(id, qty, reason)) then
      Print("usage: /ledger use <itemID> <qty> [reason] (default reason: your main profession; item must be tracked)")
    end
  elseif cmd == "loan" then
    -- /ledger loan Alex 4g 1g 7   (amount and fee: 4g, 4g50s, 75s, or a bare number of gold)
    local who, a, fee, days = rest:match("^(%S+)%s+(%S+)%s+(%S+)%s*(%d*)d?$")
    local principal, feeC = ns.ParseMoney(a), ns.ParseMoney(fee)
    days = tonumber(days)
    if who and principal and principal > 0 and feeC then
      ns.AddLoan(who, principal, feeC, days or 7)
    else
      Print("usage: /ledger loan <name> <amount> <fee> [days]  e.g. /ledger loan Alex 4g 1g 7  (days default 7)")
    end
  elseif cmd == "repay" then
    local key, amt = rest:match("^(%S*)%s*(%S*)$")
    local l, nOpen = ns.FindLoan(key)
    local amount = amt ~= "" and ns.ParseMoney(amt) or nil
    if l and (amt == "" or amount) then
      ns.RepayLoan(l, amount)
    elseif key == "" and (nOpen or 0) > 1 then
      Print("more than one open loan; say whose: /ledger repay <name|#id> [amount]")
      ns.ReportLoans()
    else
      Print("usage: /ledger repay <name|#id> [amount]  (no open loan matched; /ledger loans lists them)")
    end
  elseif cmd == "source" then
    local s = rest:lower()
    if s == "auto" or s == "ahdb" or s == "auctionator" then
      ns.db.settings.source = (s ~= "auto") and s or nil
      ns.SnapPrices()
      if ns.RefreshUI then ns.RefreshUI() end
      Print("price source: " .. s)
    else
      local t, n = ns.AHDBLastScan()
      Print("price source: " .. (ns.db.settings.source or "auto") .. "  (usage: /ledger source auto|ahdb|auctionator)")
      Print(string.format("  AHDB: %s   Auctionator: %s", t and (n .. " scans, last " .. date("%m-%d %H:%M", t))
        or (ns.HasAHDB() and "no scans yet" or "not loaded"), AuctionatorAPI() and "loaded" or "not loaded"))
    end
  elseif cmd == "vendorprice" or cmd == "vp" then
    -- /ledger vendorprice                 list corrections
    -- /ledger vendorprice <item> <amount> set (amount like 1s25; 0 = vendors won't buy it)
    -- /ledger vendorprice <item> reset    back to the item data
    local item, amt = rest:match("^(.-)%s+(%S+)$")
    local id = item and (tonumber(item) or ItemIDFromLink(item))
    if id and amt then
      if amt:lower() == "reset" then
        ns.SetVendorFix(id, nil)
        local builtIn = KNOWN_VENDOR_FIX[id]
        Print(string.format("%s: your correction removed; vendor price is %s.", ItemLabel(id) or ("item " .. id),
          builtIn and (ns.Money(builtIn) .. " (Ledger's built-in correction)") or "the item data's again"))
      else
        local c = ns.ParseMoney(amt)
        if c then
          ns.SetVendorFix(id, c)
          Print(string.format("%s: vendor price set to %s.", ItemLabel(id) or ("item " .. id), ns.Money(c)))
        else
          Print("usage: /ledger vendorprice <itemID or link> <amount, e.g. 1s25 | 0 | reset>")
        end
      end
    else
      local n = 0
      for fid, v in pairs(ns.db.vendorFix or {}) do
        Print(string.format("  %s: %s (yours)", ItemLabel(fid) or ("item " .. fid), ns.Money(v))); n = n + 1
      end
      for fid, v in pairs(KNOWN_VENDOR_FIX) do
        if not (ns.db.vendorFix and ns.db.vendorFix[fid]) then
          Print(string.format("  %s: %s (built in)", ItemLabel(fid) or ("item " .. fid), ns.Money(v))); n = n + 1
        end
      end
      Print(n == 0 and "no vendor price corrections." or
        "set one with /ledger vendorprice <item> <amount>; selling an item to a vendor also corrects it.")
    end
  elseif cmd == "craftmode" or cmd == "mats" then
    -- /ledger craftmode cheapest|ah|craft
    local m = rest:lower()
    if m == "buy" then m = "ah" end
    if m == "cheapest" or m == "ah" or m == "craft" then
      ns.db.settings.craftSource = (m ~= "cheapest") and m or nil
      if ns.RefreshUI then ns.RefreshUI() end
    end
    Print("crafting mats: " .. (ns.CraftSource and ns.CraftSource() or "cheapest")
      .. "  (usage: /ledger craftmode cheapest|ah|craft)")
  elseif cmd == "anvil" then
    -- /ledger anvil [on|off]: on = recipes may need an anvil, off = no-anvil mode
    local m = rest:lower()
    if m == "off" or m == "no" then ns.db.settings.craftNoAnvil = true
    elseif m == "on" or m == "yes" then ns.db.settings.craftNoAnvil = nil
    elseif m == "" then ns.db.settings.craftNoAnvil = not ns.db.settings.craftNoAnvil or nil end
    if ns.RefreshUI then ns.RefreshUI() end
    Print("crafting: " .. (ns.db.settings.craftNoAnvil and "no anvil (recipes needing one are hidden)"
      or "anvil recipes shown") .. "  (usage: /ledger anvil [on|off])")
  elseif cmd == "craftdepth" then
    -- /ledger craftdepth <buy units> [skip units]
    local b, k = rest:match("^(%d+)%s*(%d*)$")
    b, k = tonumber(b), tonumber(k)
    if b and b >= 1 and b <= 1000 then
      ns.db.settings.craftBuy = b
      if k and k <= 1000 then ns.db.settings.craftSkip = k end
      if ns.RefreshUI then ns.RefreshUI() end
    elseif rest ~= "" then
      Print("usage: /ledger craftdepth <buy units 1-1000> [skip units 0-1000]")
    end
    Print(string.format("crafting prices: reagents at the average of the cheapest %d units; products past the %d"
      .. " cheapest units (capped at the median).", ns.CraftBuyUnits and ns.CraftBuyUnits() or 20,
      ns.CraftSkipUnits and ns.CraftSkipUnits() or 5))
  elseif cmd == "craft" or cmd == "crafts" then
    -- /ledger craft [new] [engineering|tailoring|...] [n]  (words in any order)
    local mode, prof, n = nil, nil, nil
    for w in rest:gmatch("%S+") do
      local lw = w:lower()
      if lw == "new" then mode = "new"
      elseif tonumber(w) then n = tonumber(w)
      else prof = lw:sub(1, 1):upper() .. lw:sub(2) end
    end
    if ns.ReportCraft then ns.ReportCraft(n or 8, mode, prof) end
  elseif cmd == "loans" then
    ns.ReportLoans()
    if (ns.db.loanFees or 0) > 0 then Print("fees paid on loans so far: " .. ns.Money(ns.db.loanFees)) end
  else
    Help()
  end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

local f = CreateFrame("Frame")
local function Reg(ev) pcall(f.RegisterEvent, f, ev) end
Reg("ADDON_LOADED")
Reg("PLAYER_LOGIN")
Reg("GET_ITEM_INFO_RECEIVED")

local holdQueued = false
local function QueueHoldings()
  if holdQueued then return end
  holdQueued = true
  C_Timer.After(1, function()
    holdQueued = false
    ns.CountHoldings()
    if ns.RefreshUI then ns.RefreshUI() end
  end)
end

-- item details arriving: one redraw for a burst of them
local itemRedrawQueued = false
local function QueueItemRedraw()
  if itemRedrawQueued then return end
  itemRedrawQueued = true
  C_Timer.After(0.5, function()
    itemRedrawQueued = false
    if ns.RefreshUI then ns.RefreshUI() end
  end)
end

f:SetScript("OnEvent", function(_, event, ...)
  if event == "GET_ITEM_INFO_RECEIVED" then
    if ns.ItemInfoReceived(...) then QueueItemRedraw() end
  elseif event == "ADDON_LOADED" then
    if ... == addonName then InitDB() end
  elseif event == "PLAYER_LOGIN" then
    if not ns.db then InitDB() end
    RepairSkippedBuys() -- before PruneClicks so the clicks it needs still exist
    PruneClicks()
    HookPurchases()
    if ns.UpdateMinimapButton then pcall(ns.UpdateMinimapButton) end
    ns.ApplyVendorFixes()
    for _, ev in ipairs({
      "MAIL_INBOX_UPDATE", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
      "PLAYERBANKSLOTS_CHANGED", "BAG_UPDATE_DELAYED", "AUCTION_HOUSE_CLOSED",
      "COMMODITY_PRICE_UPDATED", "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED",
      "OWNED_AUCTIONS_UPDATED", "AUCTION_OWNED_LIST_UPDATE", "PLAYER_MONEY",
    }) do Reg(ev) end
    local api = AuctionatorAPI()
    if api and api.RegisterForDBUpdate then
      pcall(api.RegisterForDBUpdate, ns.CALLER, function()
        if ns.db then ns.db.lastScan = time() end
        ns.QueueSnap(2)
        -- after a scan, fill in vendor prices for new items and save the
        -- below-vendor list (LedgerDB.belowVendor); one quiet chat line
        C_Timer.After(10, function()
          -- silent: results show on the window's "Below vendor" tab
          ns.ScanVendorPrices(function()
            ns.BelowVendor()
            if ns.RefreshUI then ns.RefreshUI() end
          end)
        end)
      end)
    end
    -- AHDB tells listeners when a full scan has been recorded
    if AuctionDB and type(AuctionDB.Listen) == "function" then
      pcall(AuctionDB.Listen, AuctionDB, "SCAN_DATA", function()
        if ns.db then ns.db.lastScan = time() end
        ns.QueueSnap(2)
        C_Timer.After(10, function()
          ns.ScanVendorPrices(function()
            ns.BelowVendor()
            if ns.RefreshUI then ns.RefreshUI() end
          end)
        end)
      end)
    end
    ns.QueueSnap(5)
    -- remind about loans that are due within a day or overdue
    C_Timer.After(8, function()
      for _, l in ipairs(ns.OpenLoans()) do
        if l.due and l.due - time() < DAY then ns.ReportLoans(true); break end
      end
    end)
  elseif event == "PLAYER_MONEY" then
    ns.OnMoneyChanged()
  elseif event == "MAIL_INBOX_UPDATE" then
    ns.ScanInbox()
  elseif event == "BANKFRAME_OPENED" then
    ns.bankOpen = true
    QueueHoldings()
  elseif event == "BANKFRAME_CLOSED" then
    ns.bankOpen = false
  elseif event == "PLAYERBANKSLOTS_CHANGED" or event == "BAG_UPDATE_DELAYED" then
    QueueHoldings()
  elseif event == "AUCTION_HOUSE_CLOSED" then
    ns.QueueSnap(1)
  elseif event == "OWNED_AUCTIONS_UPDATED" or event == "AUCTION_OWNED_LIST_UPDATE" then
    ns.ReadOwnedAuctions()
  elseif event == "COMMODITY_PRICE_UPDATED" then
    local unit, total = ...
    if pendingBuy then pendingBuy.unit, pendingBuy.total = unit, total end
  elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
    if pendingBuy and pendingBuy.confirmed then
      table.insert(ns.db.clicks, {t = time(), itemID = pendingBuy.itemID, qty = pendingBuy.qty,
        unit = pendingBuy.unit, total = pendingBuy.total, matched = false})
    end
    pendingBuy = nil
  elseif event == "COMMODITY_PURCHASE_FAILED" then
    pendingBuy = nil
  end
end)
