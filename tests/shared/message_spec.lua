---@module 'luassert'

local Message = require("aviary.shared.message")

--- An arbitrary destination policy, deliberately independent of tool defaults.
---@param cwd? string
---@return aviary.shared.message.RenderCtx
local function context(cwd)
  return {
    cwd = cwd,
    format = function(path, first, last)
      return path .. (first and "[" .. first .. (last and "," .. last or "") .. "]" or "")
    end,
  }
end

describe("aviary.shared.message", function()
  it("composes nested rows with exact whitespace and valid empty content", function()
    local message = Message.join("\n", {
      Message.join(" ", { Message.reference("/project/a.lua", 1, 3), Message.text("first") }),
      Message.join(" ", { Message.reference("/project/b.lua", 2), Message.text("second") }),
    })
    assert.are.equal("a.lua[1,3] first\nb.lua[2] second", (message:eval(context("/project"))))
    assert.are.equal("", (Message.text(""):eval(context())))
    assert.are.equal("", (Message.join(" ", {}):eval(context())))
    assert.are.equal(
      " a ",
      (Message.join(" ", { Message.text(""), Message.text("a"), Message.text("") }):eval(context()))
    )
  end)

  it("passes raw inclusive rows to the supplied format and never changes the tree", function()
    local message = Message.reference("/project/a.lua", 2, 5)
    local before = vim.deepcopy(message)
    local seen
    assert.are.equal("custom", (message:eval({
      cwd = "/project",
      format = function(...)
        seen = { ... }
        return "custom"
      end,
    })))
    assert.are.same({ "a.lua", 2, 5 }, seen)
    assert.are.same(before, message)
    assert.are.equal("/project/a.lua[2,5]", (message:eval(context())))
    assert.are.equal("/project/a.lua[2,5]", (message:eval(context("/elsewhere"))))
  end)

  it("preserves formatted whole files, ranges and literal text without adding whitespace", function()
    assert.are.equal("a.lua", (Message.reference("/p/a.lua"):eval(context("/p"))))
    assert.are.equal("a.lua[2]", (Message.reference("/p/a.lua", 2):eval(context("/p"))))
    assert.are.equal("a.lua[2,2]", (Message.reference("/p/a.lua", 2, 2):eval(context("/p"))))
    assert.are.equal("{file} 100%\n", (Message.text("{file} 100%\n"):eval(context())))
    assert.are.equal(" custom \n", (Message.reference("/p/a.lua"):eval({
      format = function()
        return " custom \n"
      end,
    })))
  end)

  it("declines unnamed references and any non-string or empty format result", function()
    assert.is_nil((Message.reference(""):eval(context())))
    for _, format in ipairs({
      function() end,
      function()
        return ""
      end,
      function()
        return 42
      end,
    }) do
      local text, reason = Message.reference("/p/a.lua"):eval({ format = format })
      assert.is_nil(text)
      assert.is_truthy(assert(reason):find("/p/a.lua", 1, true))
    end
  end)

  it("stops at a failed child without exposing partial output", function()
    local seen = {}
    local message = Message.join(
      "\n",
      { Message.reference("/p/first"), Message.reference("/p/bad"), Message.reference("/p/skipped") }
    )
    local text, reason = message:eval({
      cwd = "/p",
      format = function(path)
        seen[#seen + 1] = path
        if path ~= "bad" then
          return path
        end
      end,
    })
    assert.is_nil(text)
    assert.are.equal("reference could not be formatted: /p/bad", reason)
    assert.are.same({ "first", "bad" }, seen)
  end)

  it("propagates format errors to the caller", function()
    assert.has_error(function()
      Message.reference("/p/a"):eval({
        format = function()
          error("bad format", 0)
        end,
      })
    end, "bad format")
  end)
end)
