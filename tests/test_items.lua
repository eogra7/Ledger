local W = require("wow")
local tests = {}

local function withRedraws(ns)
  local n = {count = 0}
  ns.RefreshUI = function() n.count = n.count + 1 end
  return n
end

local function withWindow(opts)
  opts.recipes = W.ENGINEERING
  local ns = W.load(opts)
  W.fire("TRADE_SKILL_SHOW")
  ns.QueueCapture()
  W.runTimers()
  return ns
end

function tests.vendor_price_fills_in_when_item_data_arrives(T)
  local ns = withWindow({unloaded = {[4380] = true}})
  local redraws = withRedraws(ns)
  local r = W.row(ns, 4380)
  T.eq(r.floor, nil, "no vendor price yet")
  T.ok(W.requested[4380], "load requested")
  W.deliver(4380)
  W.runTimers()
  T.eq(redraws.count, 1, "window redrawn once")
  T.eq(W.row(ns, 4380).floor, 450, "floor: vendor 800 - mats 350")
  T.eq(ns.db.vendor[4380], 800, "vendor price saved")
end

function tests.burst_of_items_redraws_once(T)
  local ns = W.load({unloaded = {[2841] = true, [4306] = true}})
  local redraws = withRedraws(ns)
  T.eq(ns.ItemName(2841), nil, "not loaded")
  T.eq(ns.ItemName(4306), nil, "not loaded")
  W.deliver(2841); W.deliver(4306)
  W.runTimers()
  T.eq(redraws.count, 1, "one redraw")
  T.eq(ns.ItemName(2841), "Bronze Bar", "name now")
end

function tests.unrequested_or_failed_items_dont_redraw(T)
  local ns = W.load({unloaded = {[2841] = true}})
  local redraws = withRedraws(ns)
  W.deliver(4306)            -- never asked for
  ns.ItemName(2841)
  W.deliver(2841, false)     -- the client can't load it
  W.runTimers()
  T.eq(redraws.count, 0, "no redraws")
  local before = W.requested[2841]
  ns.ItemName(2841)
  T.eq(W.requested[2841], before, "not asked for again")
end

function tests.works_without_global_GetItemInfo(T)
  local ns = W.load({noGlobalGetItemInfo = true})
  T.eq(ns.ItemName(4380), "Big Bronze Bomb", "name via C_Item")
  T.eq(ns.SellPrice(4380), 800, "vendor price via C_Item")
end

function tests.bank_keeps_names_from_slot_links(T)
  local ns = W.load({bank = {{2841, 20}, {4306, 5}}, unloaded = {[2841] = true}})
  ns.bankOpen = true
  ns.CountHoldings()
  local d = ns.BankValue(false)
  local names = {}
  for _, r in ipairs(d.rows) do names[r.id] = r.savedName end
  T.eq(names[2841], "Bronze Bar", "unloaded item named from its link")
  T.eq(names[4306], "Silk Cloth", "loaded item")
  -- names survive a reload, when the client has loaded nothing yet
  local again = W.load({db = ns.db, unloaded = {[2841] = true}})
  for _, r in ipairs(again.BankValue(false).rows) do
    if r.id == 2841 then T.eq(r.savedName, "Bronze Bar", "after reload") end
  end
end

function tests.blank_profession_dropped(T)
  local ns = W.load({db = {seeded = 1, recipeProfs = {[""] = {n = 47, rank = 0}, Tailoring = {n = 3, rank = 68}},
    recipes = {[1] = {product = 1, prof = "", reagents = {{2840, 1}}}}}})
  T.eq(ns.db.recipeProfs[""], nil, "blank profession removed")
  T.ok(ns.db.recipeProfs.Tailoring, "real one kept")
  T.eq(ns.db.recipes[1], nil, "its recipes removed")
  -- a window that reports no profession name records nothing
  local ns2 = withWindow({recipes = nil})
  W.setWindow({"", 0, W.ENGINEERING[3]})
  T.eq(ns2.CaptureRecipes(), 0, "nothing captured")
  T.eq(ns2.db.recipeProfs[""], nil, "still no blank profession")
end

return tests
