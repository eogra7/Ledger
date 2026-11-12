local W = require("wow")
local tests = {}

-- Open the profession window: Ledger reads it after a short timer.
local function withWindow(win, db)
  local ns = W.load({db = db, recipes = win})
  W.fire("TRADE_SKILL_SHOW")
  if ns.QueueCapture then ns.QueueCapture() end
  W.runTimers()
  return ns
end

function tests.capture_reads_recipes_and_tools(T)
  local ns = withWindow(W.ENGINEERING)
  local r = ns.db.recipes[4371]
  T.ok(r, "Bronze Tube recorded")
  T.eq(r.prof, "Engineering", "profession")
  T.eq(r.anvil, true, "needs an anvil")
  T.eq(table.concat(r.tools, ","), "Anvil,Blacksmith Hammer", "tools")
  T.eq(ns.db.recipes[4380].anvil, nil, "bomb needs no anvil")
  T.eq(ns.db.recipeProfs.Engineering.rank, 150, "rank")
end

function tests.cheapest_crafts_parts_when_cheaper(T)
  local ns = withWindow(W.ENGINEERING)
  local r = W.row(ns, 4380)
  -- tube: craft 2 x 100 = 200 < 500 on the AH; silk 3 x 50 = 150
  T.eq(r.cost, 350, "mats")
  local tube
  for _, rg in ipairs(r.reagents) do if rg.id == 4371 then tube = rg end end
  T.eq(tube.how, "craft", "tube crafted")
  -- sells for 1000 on the AH, 950 after the 5% cut (vendor pays 800)
  T.eq(r.profit, 600, "profit")
end

function tests.buy_ah_mode_buys_parts(T)
  local ns = withWindow(W.ENGINEERING)
  ns.db.settings.craftSource = "ah"
  local r = W.row(ns, 4380)
  T.eq(r.cost, 650, "mats (tube bought at 500)")
  T.eq(r.costCheapest, 350, "cheapest mix")
end

function tests.no_anvil_hides_and_buys_anvil_recipes(T)
  local ns = withWindow(W.ENGINEERING)
  ns.db.settings.craftNoAnvil = true
  T.eq(W.row(ns, 4371), nil, "tube hidden")
  local r = W.row(ns, 4380)
  T.eq(r.cost, 650, "tube bought instead of crafted")
end

function tests.shopping_list_quantities_and_cost(T)
  local ns = withWindow(W.ENGINEERING)
  local list = ns.CraftShoppingList(W.row(ns, 4380), 10)
  local qty = {}
  for _, e in ipairs(list.ah) do qty[e.id] = e.qty end
  T.eq(qty[2841], 20, "bronze bars")
  T.eq(qty[4306], 30, "silk")
  T.eq(qty[4371], nil, "tube not bought")
  T.eq(list.cost, 3500, "total")
end

function tests.vendor_per_hour_needs_every_craft_timed(T)
  local ns = withWindow(W.ENGINEERING)
  ns.RecordCraftTime(4380, 5)
  local r = W.row(ns, 4380)
  T.eq(r.perHour, nil, "blank while the tube is untimed")
  T.eq(r.untimed[1], 4371, "tube listed as untimed")
  ns.RecordCraftTime(4371, 2)
  r = W.row(ns, 4380)
  T.eq(r.secs, 7, "5 s bomb + 2 s tube")
  -- vendor floor: 800 - 350 = 450 per craft, 7 s each
  T.eq(r.perHour, math.floor(450 * 3600 / 7), "vendor per hour")
end

function tests.main_profession_follows_opened_windows(T)
  local ns = W.load()
  T.eq(ns.MainCraftProf(), "Engineering", "default")
  ns = withWindow({"Blacksmithing", 40, {{2851, "Copper Chain Belt", 1, {{2840, 6}}, {"Anvil"}}}})
  T.eq(ns.MainCraftProf(), "Blacksmithing", "after opening Blacksmithing")
  T.eq(ns.CraftProfList()[1], "Blacksmithing", "listed first")
  local belt = W.row(ns, 2851)
  T.eq(belt.cost, 180, "6 copper bars")
  T.eq(belt.learned, true, "learned")
  -- built-in Engineering guesses don't count as known for a blacksmith
  for _, r in ipairs(ns.CraftMargins()) do
    if r.seed then T.eq(r.learned, false, "seed " .. r.id .. " not learned") end
  end
end

function tests.gearquest_recipes_show_as_not_learned(T)
  local gq = {CraftSkills = {[2857] = {profession = "Blacksmithing", skill = 25, reagents = {{2840, 6}}}}}
  local ns = W.load({gearquest = gq})
  local r = W.row(ns, 2857)
  T.ok(r, "listed")
  T.eq(r.learned, false, "not learned")
  T.eq(r.src, "gearquest", "source")
end

return tests
