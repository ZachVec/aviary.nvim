---@module 'luassert'

local Editor = require("aviary.shared.editor")

describe("aviary.shared.editor selection", function()
  local source, buffer

  before_each(function()
    source = vim.api.nvim_get_current_buf()
    buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "one", "two", "three", "four" })
    vim.api.nvim_set_current_buf(buffer)
  end)

  after_each(function()
    vim.cmd("normal! \27")
    vim.api.nvim_set_current_buf(source)
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)

  for _, visual in ipairs({
    { name = "characterwise", keys = "v" },
    { name = "linewise", keys = "V" },
    { name = "blockwise", keys = "\22" },
  }) do
    for _, backwards in ipairs({ false, true }) do
      local direction = backwards and "backward" or "forward"
      it("captures " .. direction .. " " .. visual.name .. " Visual lines and exits Visual mode", function()
        vim.api.nvim_buf_set_mark(buffer, "<", 1, 0, {})
        vim.api.nvim_buf_set_mark(buffer, ">", 1, 0, {})
        vim.cmd("normal! " .. (backwards and "3G0" or "2G0") .. visual.keys .. (backwards and "k" or "j"))
        assert.are.equal(visual.keys, vim.api.nvim_get_mode().mode)

        assert.are.same({ 2, 3 }, { Editor.selection() })
        assert.are.equal("n", vim.api.nvim_get_mode().mode)
      end)
    end
  end

  it("uses the cursor line in an unnamed buffer instead of stale Visual marks", function()
    vim.api.nvim_buf_set_mark(buffer, "<", 2, 0, {})
    vim.api.nvim_buf_set_mark(buffer, ">", 3, 0, {})
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    assert.are.equal("", vim.api.nvim_buf_get_name(buffer))
    assert.are.equal("n", vim.api.nvim_get_mode().mode)

    assert.are.same({ 4, 4 }, { Editor.selection() })
  end)
end)

describe("aviary.shared.editor text width", function()
  local win, source, buffer, options
  before_each(function()
    win = vim.api.nvim_get_current_win()
    source = vim.api.nvim_get_current_buf()
    buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(win, buffer)
    options = {}
    for name, value in pairs({
      number = true,
      relativenumber = false,
      numberwidth = 4,
      signcolumn = "yes",
      foldcolumn = "2",
      statuscolumn = "",
    }) do
      options[name] = vim.wo[win][name]
      vim.wo[win][name] = value
    end
  end)
  after_each(function()
    vim.api.nvim_win_set_buf(win, source)
    for name, value in pairs(options) do
      vim.wo[win][name] = value
    end
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)

  it("predicts native number-column changes without writing replacement rows", function()
    for _, count in ipairs({ 1, 99, 999, 1000, 999, 0 }) do
      local previous = vim.api.nvim_buf_line_count(buffer)
      local expected = Editor.text_width(win, count)
      assert.are.equal(previous, vim.api.nvim_buf_line_count(buffer))
      local rows = {}
      for _ = 1, count do
        rows[#rows + 1] = ""
      end
      vim.api.nvim_buf_set_lines(buffer, 0, -1, false, rows)
      assert.are.equal(expected, Editor.text_width(win))
    end
  end)

  it("keeps measured gutters for relative-only numbering and custom status columns", function()
    vim.wo[win].number = false
    vim.wo[win].relativenumber = true
    assert.are.equal(Editor.text_width(win), Editor.text_width(win, 100000))
    vim.wo[win].number = true
    vim.wo[win].statuscolumn = "%l"
    assert.are.equal(Editor.text_width(win), Editor.text_width(win, 100000))
    assert.are.equal(1, vim.api.nvim_buf_line_count(buffer))
  end)
end)
