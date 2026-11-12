local W = require("wow")
local tests = {}

local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

function tests.money_formatting(T)
  local ns = W.load()
  T.eq(ns.Money(0), "0c", "0")
  T.eq(ns.Money(45), "45c", "copper")
  T.eq(ns.Money(1205), "12s05", "silver")
  T.eq(ns.Money(123456), "12g34s56", "gold")
  T.eq(ns.Money(-1205), "-12s05", "negative")
end

function tests.new_install_starts_empty(T)
  local ns = W.load()
  T.eq(count(ns.db.positions), 0, "positions")
  T.eq(#ns.db.trades, 0, "trades")
  T.ok(ns.db.seeded, "seeded time set")
end

-- installs from before v0.9.1 were given placeholder "seed" positions
local function seededDB(when)
  return {seeded = when, positions = {
      [2840] = {name = "Copper Bar", qty = 25, cost = 1940, realized = 0},
      [4306] = {name = "Silk Cloth", qty = 5, cost = 1255, realized = 0},
      [3575] = {name = "Iron Bar", qty = 10, cost = 3000, realized = 0}},
    trades = {
      {type = "seed", itemID = 2840, qty = 20, gross = 1440},
      {type = "seed", itemID = 4306, qty = 5, gross = 1255},
      {type = "buy", itemID = 2840, qty = 5, gross = 500},
      {type = "buy", itemID = 3575, qty = 10, gross = 3000}}}
end

function tests.stray_seeds_removed_keeping_own_buys(T)
  local ns = W.load({db = seededDB(W.NOW - 3600)})
  local p = ns.db.positions
  T.eq(count(p), 2, "positions left")
  T.eq(p[2840].qty, 5, "copper qty (own buy)")
  T.eq(p[2840].cost, 500, "copper cost (own buy)")
  T.eq(p[3575].qty, 10, "iron untouched")
  T.eq(p[4306], nil, "seed-only position dropped")
  T.eq(#ns.db.trades, 2, "trades left")
  -- runs once
  local again = W.load({db = ns.db})
  T.eq(count(again.db.positions), 2, "second load")
end

function tests.early_installs_keep_their_seeds(T)
  local ns = W.load({db = seededDB(1794115567)}) -- before the v0.9.1 cutoff
  T.eq(count(ns.db.positions), 3, "positions")
  T.eq(ns.db.positions[2840].qty, 25, "copper")
  T.eq(#ns.db.trades, 4, "trades")
end

return tests
