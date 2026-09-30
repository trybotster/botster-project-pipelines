-- Strict globals: the plugin's Lua uses no global that the sandbox lacks.
-- Run: botster-plugin-test --plugin . test/globals_spec.lua
--
-- Regression: plugin.lua called the bare global `events.emit` (the sandbox has
-- `botster.events.emit`) inside a pcall, so question.opened and pr_merged were
-- silently never emitted. No fake-runtime test reached the real sandbox, so
-- every test passed. The check parses the plugin's Lua and compares every
-- global name with the sandbox's real global set.
local kit = require("botster.test")

kit.test("project-pipelines uses no global name that the sandbox does not define", function(t)
  local p = t:load(".")
  local found = p:undefined_globals()
  local names = {}
  for _, use in ipairs(found) do
    names[#names + 1] = use.file .. ":" .. use.line .. " " .. use.name
  end
  t:eq(#found, 0, "undefined globals: " .. table.concat(names, ", "))
end)
