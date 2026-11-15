---@module 'luassert'

local Text = require("aviary.shared.text")

describe("aviary.shared.text padding", function()
  it("aligns text by display width and returns its byte span", function()
    assert.are.same({ "abc  ", 0, 3 }, { Text.padding("abc", "left", 5) })
    assert.are.same({ "  abc", 2, 3 }, { Text.padding("abc", "right", 5) })
    assert.are.same({ "中  ", 0, 3 }, { Text.padding("中", "left", 4) })
    assert.are.same({ "  中", 2, 3 }, { Text.padding("中", "right", 4) })
    assert.are.same({ " é", 1, 3 }, { Text.padding("é", "right", 2) })
  end)

  it("keeps text that already meets or exceeds the requested width", function()
    assert.are.same({ "中", 0, 3 }, { Text.padding("中", "left", 2) })
    assert.are.same({ "中", 0, 3 }, { Text.padding("中", "right", 1) })
    assert.are.same({ "text", 0, 4 }, { Text.padding("text", "left", 0) })
  end)

  it("returns a zero-length span for empty text", function()
    assert.are.same({ "   ", 0, 0 }, { Text.padding("", "left", 3) })
    assert.are.same({ "   ", 3, 0 }, { Text.padding("", "right", 3) })
    assert.are.same({ "", 0, 0 }, { Text.padding("", "right", 0) })
  end)
end)

describe("aviary.shared.text truncate", function()
  it("keeps fitting text and shortens either the tail or the middle", function()
    assert.are.equal("", Text.truncate("", "end", 0))
    assert.are.equal("abc", Text.truncate("abc", "end", 3))
    assert.are.equal("abc…", Text.truncate("abcdef", "end", 4))
    assert.are.equal("ab…ef", Text.truncate("abcdef", "middle", 5))
    assert.are.equal("a…ef", Text.truncate("abcdef", "middle", 4))
    assert.are.equal("…", Text.truncate("abcdef", "end", 0))
    assert.are.equal("…", Text.truncate("abcdef", "middle", 1))
  end)

  it("preserves multibyte and composing characters while counting display cells", function()
    assert.are.equal("中…", Text.truncate("中文路径", "end", 4))
    assert.are.equal("中…径", Text.truncate("中文路径", "middle", 5))
    assert.are.equal("é…", Text.truncate("éabc", "end", 2))
    assert.are.equal("…é", Text.truncate("abcé", "middle", 2))
  end)

  it("accounts for the ellipsis width under double-width ambiguous characters", function()
    local previous = vim.o.ambiwidth
    vim.o.ambiwidth = "double"
    local ok, reason = pcall(function()
      assert.are.equal("a…", Text.truncate("abcdef", "end", 3))
      assert.are.equal("a…f", Text.truncate("abcdef", "middle", 4))
      assert.are.equal("…", Text.truncate("abcdef", "middle", 0))
    end)
    vim.o.ambiwidth = previous
    assert(ok, reason)
  end)
end)
