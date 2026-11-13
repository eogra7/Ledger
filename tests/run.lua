-- Ledger's test runner. From the add-on folder:   lua tests/run.lua
-- (Lua 5.1, like the game; 5.3/5.4 work too.) Exits non-zero if any test fails.
local dir = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "tests"
package.path = dir .. "/?.lua;" .. package.path

local FILES = {"test_portfolio", "test_craft", "test_items"}

local T = {}
function T.eq(got, want, what)
  if got ~= want then
    error(string.format("%s: expected %s, got %s", what or "value", tostring(want), tostring(got)), 2)
  end
end
function T.ok(v, what) if not v then error((what or "expected true") , 2) end end

local pass, fail = 0, 0
for _, name in ipairs(FILES) do
  local tests = require(name)
  local names = {}
  for k in pairs(tests) do names[#names + 1] = k end
  table.sort(names)
  for _, k in ipairs(names) do
    local ok, err = pcall(tests[k], T)
    if ok then
      pass = pass + 1
      print("  ok    " .. name .. ": " .. k)
    else
      fail = fail + 1
      print("  FAIL  " .. name .. ": " .. k .. "\n        " .. tostring(err))
    end
  end
end
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
