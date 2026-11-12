local W = require("wow")
local tests = {}

-- A client where the global GetItemInfo gives nothing, but C_Item knows every item.
local function cItemOnlyClient()
  return {
    GetItemInfo = function() return nil end,
    C_Item = {
      GetItemNameByID = function(id) return W.ITEMS[id] and W.ITEMS[id][1] end,
      GetItemInfo = function(id)
        local it = W.ITEMS[id]
        if not it then return nil end
        return it[1], "item:" .. id, nil, nil, nil, nil, nil, nil, nil, nil, it[2]
      end,
      RequestLoadItemDataByID = function() end,
    },
  }
end

local function bankDB()
  return {bankItems = {t = W.NOW - 60, items = {[4380] = {n = 2}, [3575] = {n = 5}}}}
end

local function bankRow(ns, id)
  for _, r in ipairs(ns.BankValue(false).rows) do if r.id == id then return r end end
  return nil
end

function tests.rows_named_when_only_c_item_knows_the_item(T)
  local ns = W.load({db = bankDB(), client = cItemOnlyClient()})
  T.eq(bankRow(ns, 4380).name, "Big Bronze Bomb", "priced item")
  T.eq(bankRow(ns, 3575).name, "Iron Bar", "unpriced item")
end

function tests.unlisted_items_get_vendor_price_from_c_item(T)
  local client = cItemOnlyClient()
  local cGetItemInfo = client.C_Item.GetItemInfo
  client.C_Item.GetItemInfo = function(id)
    if id == 3575 then return "Iron Bar", "item:3575", nil, nil, nil, nil, nil, nil, nil, nil, 50 end
    return cGetItemInfo(id)
  end
  local ns = W.load({db = bankDB(), client = client})
  local r = bankRow(ns, 3575)
  T.eq(r.vendor, 50, "vendor price")
  T.eq(r.how, "vendor", "priced by")
  T.eq(r.value, 250, "value (5 x 50c)")
end

return tests
