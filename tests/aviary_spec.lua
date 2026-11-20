---@module 'luassert'

--- Install a public/shared fake module; return its recorded options and cleanup.
---@param name string
---@param shared? boolean
---@return table applied
---@return fun()
local function fake_module(name, shared)
  local path = shared and ("aviary.shared." .. name) or ("aviary." .. name)
  local applied = {}
  package.preload[path] = function()
    return {
      setup = function(slice)
        applied[#applied + 1] = slice
        return true, nil
      end,
    }
  end
  return applied,
    function()
      package.preload[path] = nil
      package.loaded[path] = nil
      local aviary = package.loaded["aviary"]
      if aviary then
        if not shared then
          aviary[name] = nil
        end
        aviary.config[name] = nil
      end
    end
end

describe("aviary", function()
  it("loads, exposes setup, and holds a config table", function()
    local aviary = require("aviary")
    assert.are.equal("table", type(aviary))
    assert.are.equal("function", type(aviary.setup))
    assert.are.equal("table", type(aviary.config))
  end)

  it("loads every module it is asked to configure, and hands it the slice", function()
    local applied, cleanup = fake_module("fake")
    require("aviary").setup({ fake = { picker = "snacks" } })

    assert.is_not_nil(package.loaded["aviary.fake"])
    assert.are.equal(1, #applied)
    assert.are.equal("snacks", applied[1].picker)
    cleanup()
  end)

  it("configures a module that was loaded before the call", function()
    local applied, cleanup = fake_module("fake")
    local aviary = require("aviary")
    assert.is_not_nil(aviary.fake)

    aviary.setup({ fake = { size = 25 } })
    assert.are.equal(25, applied[1].size)
    cleanup()
  end)

  it("rejects shared modules named in setup", function()
    local applied, cleanup = fake_module("fake", true)
    assert.has_error(function()
      require("aviary").setup({ fake = { size = 25 } })
    end)
    assert.is_nil(package.loaded["aviary.shared.fake"])
    assert.are.equal(0, #applied)
    cleanup()
  end)

  it("prefers a public module when a name exists in both tiers", function()
    local feature, feature_cleanup = fake_module("fake")
    local shared, shared_cleanup = fake_module("fake", true)
    require("aviary").setup({ fake = { size = 25 } })

    assert.are.equal(1, #feature)
    assert.are.equal(0, #shared)
    feature_cleanup()
    shared_cleanup()
  end)

  it("rejects private setup paths and non-table root options", function()
    local aviary = require("aviary")
    for _, name in ipairs({ "pigeon.config", "pigeon.backends", "shared.path" }) do
      assert.has_error(function()
        aviary.setup({ [name] = {} })
      end)
    end
    assert.has_error(function()
      ---@diagnostic disable-next-line: param-type-mismatch
      aviary.setup(false)
    end, "aviary: options must be a table")
  end)

  it("replaces a named module's earlier overrides on each setup", function()
    local applied, cleanup = fake_module("fake")
    local aviary = require("aviary")
    aviary.setup({ fake = { position = "left" } })
    aviary.setup({ fake = { size = "40%" } })

    assert.is_nil(aviary.config.fake.position)
    assert.are.equal("40%", aviary.config.fake.size)
    assert.are.same({ size = "40%" }, applied[2])
    cleanup()
  end)

  it("rebuilds a named feature from defaults instead of previous root overrides", function()
    local aviary = require("aviary")
    local Config = require("aviary.pigeon.config")
    local saved, original = vim.deepcopy(aviary.config), vim.deepcopy(Config())
    aviary.setup({ pigeon = { view = { width = 80 }, prompts = { custom = "Review {file}" } } })
    aviary.setup({ pigeon = { view = { height = 0.5 } } })
    local running, applied = vim.deepcopy(Config()), vim.deepcopy(aviary.config.pigeon)
    aviary.pigeon.setup(original)
    aviary.config = saved
    assert.are.equal(0.9, running.view.width)
    assert.is_nil(running.prompts.custom)
    assert.are.equal(0.5, running.view.height)
    assert.are.same({ view = { height = 0.5 } }, applied)
  end)

  it("resets omitted modules and keeps resetting them on empty setup calls", function()
    local first, clear_first = fake_module("reset_first")
    local second, clear_second = fake_module("reset_second")
    local aviary = require("aviary")
    aviary.setup({ reset_first = { size = 25 } })
    aviary.setup({ reset_second = { position = "left" } })
    aviary.setup({})
    aviary.setup()
    local first_calls, second_calls = vim.deepcopy(first), vim.deepcopy(second)
    local first_config, second_config = aviary.config.reset_first, aviary.config.reset_second
    clear_first()
    clear_second()
    assert.are.same({ { size = 25 }, {}, {}, {} }, first_calls)
    assert.are.same({ { position = "left" }, {}, {} }, second_calls)
    assert.are.same({}, first_config)
    assert.are.same({}, second_config)
  end)

  it("leaves a module nobody names alone", function()
    package.preload["aviary.untouched"] = function()
      return { setup = function() end }
    end
    local aviary = require("aviary")
    aviary.setup({})
    assert.is_nil(package.loaded["aviary.untouched"])
    package.preload["aviary.untouched"] = nil
  end)

  it("refuses a name that is not a configurable module, without configuring", function()
    local aviary = require("aviary")
    local before = vim.deepcopy(aviary.config)
    local ok, err = pcall(function()
      aviary.setup({ tree = { size = 1 } })
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("not a configurable module", 1, true))
    assert.are.same(before, aviary.config)
  end)

  it("returns itself from setup", function()
    local aviary = require("aviary")
    assert.are.equal(aviary, aviary.setup({}))
  end)

  it("lazily loads a feature when it is named", function()
    package.preload["aviary.fake"] = function()
      return { loaded = true }
    end
    local aviary = require("aviary")
    assert.is_true(aviary.fake.loaded)
    assert.is_true(package.loaded["aviary.fake"].loaded)
    package.preload["aviary.fake"] = nil
    package.loaded["aviary.fake"] = nil
  end)

  it("keeps shared modules and utility functions off the root table", function()
    local aviary = require("aviary")
    for _, name in ipairs({
      "shared",
      "notify",
      "path",
    }) do
      local ok, err = pcall(function()
        return aviary[name]
      end)
      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("module 'aviary." .. name .. "' not found", 1, true))
      assert.is_nil(rawget(aviary, name))
    end
  end)

  it("leaves shared modules unloaded and allows features to import them while loading", function()
    local result = vim
      .system({
        vim.v.progpath,
        "--headless",
        "-u",
        "NONE",
        "-i",
        "NONE",
        "-c",
        "lua "
          .. [[
        vim.opt.rtp:prepend(vim.fn.getcwd())
        local aviary = require("aviary")
        for _, name in ipairs({ "async", "debounce", "editor", "notify", "path", "process", "protect", "resources", "text", "transaction" }) do
          assert(package.loaded["aviary.shared." .. name] == nil)
        end
        assert(rawget(aviary, "util") == nil)
        local seen
        vim.notify = function(msg) seen = msg end
        package.preload["aviary.fake"] = function()
          require("aviary.shared.notify").warn("feature loading")
          return { loaded = true }
        end
        assert(aviary.fake.loaded)
        assert(seen == "feature loading")
        assert(package.loaded["aviary.shared.notify"] ~= nil)
        assert(rawget(aviary, "notify") == nil)
        assert(package.loaded["aviary.shared.path"] == nil)
        assert(package.loaded["aviary.shared.process"] == nil)
        assert(package.loaded["aviary.hawk"] == nil)
        assert(package.loaded["aviary.pigeon"] == nil)
      ]],
        "-c",
        "qa!",
      }, { text = true })
      :wait()
    assert.are.equal(0, result.code, result.stderr)
    assert.are.equal("", result.stderr)
  end)

  it("loads shared dependencies only when their behavior is needed", function()
    local result = vim
      .system({
        vim.v.progpath,
        "--headless",
        "-u",
        "NONE",
        "-i",
        "NONE",
        "-c",
        "lua " .. [[
        vim.opt.rtp:prepend(vim.fn.getcwd())
        local Async = require("aviary.shared.async")
        Async.run(function() end)
        Async.run(function() error("custom", 0) end, function() end)
        local protect = require("aviary.shared.protect")
        assert(protect(function() end)())
        assert(package.loaded["aviary.shared.notify"] == nil)
        local Path = require("aviary.shared.path")
        assert(Path.truncate("lua/aviary/shared/util/path.lua", 22) == "lua/…/util/path.lua")
        assert(package.loaded["aviary.shared.text"] == nil)
        assert(Path.truncate("long_directory/path.lua", 6) == "pa…lua")
        assert(package.loaded["aviary.shared.text"] ~= nil)
        local seen
        vim.notify = function(msg) seen = msg end
        local ok, err = protect(function() error("failure", 0) end)()
        assert(not ok and err == "failure" and seen == "failure")
        assert(package.loaded["aviary.shared.notify"] ~= nil)
      ]],
        "-c",
        "qa!",
      }, { text = true })
      :wait()
    assert.are.equal(0, result.code, result.stderr)
    assert.are.equal("", result.stderr)
  end)

  it("rejects shared module names as public setup names", function()
    local aviary = require("aviary")
    local before = vim.deepcopy(aviary.config)
    local ok, err = pcall(aviary.setup, { path = {} })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("path is not a configurable module", 1, true))
    assert.are.same(before, aviary.config)
  end)

  it("does not save a rejected slice and can retry from its previous valid config", function()
    local aviary = require("aviary")
    aviary.setup({ pigeon = { view = { width = 80 } } })
    assert.has_error(function()
      aviary.setup({ pigeon = { view = { width = false } } })
    end)
    assert.are.equal(80, aviary.config.pigeon.view.width)
    assert.are.equal(80, require("aviary.pigeon.config")().view.width)
    aviary.setup({ pigeon = { view = { width = 90 } } })
    assert.are.equal(90, aviary.config.pigeon.view.width)
    aviary.setup({ pigeon = {} })
  end)

  it("applies the same non-root configuration repeatedly without changing its meaning", function()
    for _, spec in ipairs({
      { name = "aviary.hawk", opts = { keymaps = { close = { "Q" } } } },
      { name = "aviary.pigeon", opts = { view = { width = 0.8 }, prompts = { custom = "{file}" } } },
    }) do
      local module = require(spec.name)
      local config = require(spec.name .. ".config")
      assert.is_true(module.setup(spec.opts))
      local before = vim.deepcopy(config())
      assert.is_true(module.setup(spec.opts))
      assert.are.same(before, config())
      assert.is_true(module.setup())
    end
  end)

  it("preserves rejected root slices and module state with useful errors for every owner", function()
    local aviary = require("aviary")
    local saved = vim.deepcopy(aviary.config)
    for _, spec in ipairs({
      {
        name = "hawk",
        path = "aviary.hawk",
        valid = { keymaps = { close = { "Q" } } },
        invalid = { keymaps = false },
        field = "keymaps",
      },
      {
        name = "pigeon",
        path = "aviary.pigeon",
        valid = { view = { width = 0.8 } },
        invalid = { view = { width = false } },
        field = "view width/height",
      },
    }) do
      local module = require(spec.path)
      local config = require(spec.path .. ".config")
      local original = vim.deepcopy(config())
      aviary.config[spec.name] = nil
      aviary.setup({ [spec.name] = spec.valid })
      local root_snapshot, module_snapshot = vim.deepcopy(aviary.config), vim.deepcopy(config())
      local ok, message = pcall(aviary.setup, { [spec.name] = spec.invalid })
      assert.is_false(ok)
      assert.is_truthy(message:find(spec.name .. ":", 1, true))
      assert.is_truthy(message:find(spec.field, 1, true))
      assert.is_truthy(message:find("must be", 1, true))
      assert.are.same(root_snapshot, aviary.config)
      assert.are.same(module_snapshot, config())
      module.setup(original)
    end
    aviary.config = saved
  end)

  it("retains successful slices and stops at a rejected slice without promising order", function()
    local aviary = require("aviary")
    local saved = vim.deepcopy(aviary.config)
    local calls, running, opts = {}, {}, {}
    for _, name in ipairs({ "batch_one", "batch_two", "batch_three" }) do
      local path = "aviary." .. name
      aviary.config[name] = { nested = { value = "old" } }
      running[name] = { nested = { value = "old" } }
      opts[name] = { nested = { value = "new" } }
      package.preload[path] = function()
        return {
          setup = function(slice)
            calls[#calls + 1] = name
            if #calls == 2 then
              return false, name .. ": rejected test value"
            end
            running[name] = vim.deepcopy(slice)
            return true, nil
          end,
        }
      end
    end
    local ok, message = pcall(aviary.setup, opts)
    for name in pairs(opts) do
      package.preload["aviary." .. name] = nil
      package.loaded["aviary." .. name] = nil
    end
    local applied = vim.deepcopy(aviary.config)
    aviary.config = saved
    assert.is_false(ok)
    assert.are.equal(2, #calls)
    assert.are.equal(calls[2] .. ": rejected test value", message)
    for name in pairs(opts) do
      local expected = { nested = { value = name == calls[1] and "new" or "old" } }
      assert.are.same(expected, applied[name])
      assert.are.same(expected, running[name])
    end
  end)

  it("sets no global", function()
    require("aviary")
    assert.is_nil(rawget(_G, "Aviary"))
  end)
end)
