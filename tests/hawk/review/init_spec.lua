---@module 'luassert'

local api = vim.api
local hawk = require("aviary").hawk
local Config = require("aviary.hawk.config")
local Git = require("aviary.hawk.git")
local h = require("hawk.helpers")

describe("Hawk Review UI", function()
  local source, cwd, dir, other, notify, diff, notes

  before_each(function()
    source, cwd = api.nvim_get_current_win(), vim.fn.getcwd(-1, -1)
    notify, diff, notes = vim.notify, Git.diff, {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(message, level)
      notes[#notes + 1] = { message = message, level = level }
    end
    dir, other = h.repo(), nil
    h.write(dir, "a.txt", { "old" })
    h.commit(dir)
    h.write(dir, "a.txt", { "new" })
    h.commit(dir)
    vim.cmd.cd(dir)
    Config.setup()
  end)

  after_each(function()
    vim.cmd.cd(cwd)
    h.cleanup(source, dir)
    h.flush()
    if other then
      vim.fn.delete(other, "rf")
    end
    vim.notify, Git.diff = notify, diff
    Config.setup()
  end)

  it("starts with empty inputs and queries only after r with both drafts set", function()
    local queries = 0
    Git.diff = function(...)
      queries = queries + 1
      return diff(...)
    end
    local tab = h.open()
    assert.are.same({ "direct", " ", " " }, h.lines(tab.bufnr))
    assert.is_false(vim.bo[tab.bufnr].modifiable)
    assert.is_false(vim.wo.number)
    assert.is_false(vim.wo.relativenumber)
    assert.are.equal("no", vim.wo.signcolumn)
    assert.is_false(vim.wo.foldenable)
    assert.are.equal("0", vim.wo.foldcolumn)
    assert.are.equal("", vim.wo.statuscolumn)
    assert.are.same({ 1, 0 }, api.nvim_win_get_cursor(0))
    assert.matches("^Review #%d+$", vim.fn.bufname(tab.bufnr))

    h.press("r")
    h.edit_input(2, "HEAD~1")
    h.press("r")
    h.edit_input(3, "HEAD")
    assert.are.equal(0, queries)
    assert.are.same({ "direct", "HEAD~1", "HEAD" }, h.lines(tab.bufnr))

    h.press("r")
    h.wait_for(function()
      return api.nvim_buf_line_count(tab.bufnr) == 4
    end)
    assert.are.equal(1, queries)
    assert.are.same({ "direct", "HEAD~1", "HEAD", "[ ] M a.txt +1 -1" }, h.lines(tab.bufnr))
    assert.matches("HEAD~1", vim.fn.bufname(tab.bufnr))
  end)

  it("keeps the reserved to interface raising", function()
    local tab = h.open()
    assert.has_error(function()
      tab:to("worktree")
    end, "aviary.hawk: snapshot switching is not implemented")
  end)

  it("selects the comparison style through the style row", function()
    local queries, finished = 0, 0
    Git.diff = function(...)
      queries = queries + 1
      local entries = diff(...)
      finished = finished + 1
      return entries
    end
    local tab = h.open()
    h.edit_input(2, "HEAD~1")
    h.edit_input(3, "HEAD")
    h.press("r")
    h.wait_for(function()
      return api.nvim_buf_line_count(tab.bufnr) == 4
    end)
    assert.are.same({ "direct", "HEAD~1", "HEAD", "[ ] M a.txt +1 -1" }, h.lines(tab.bufnr))
    assert.are.equal(1, queries)

    h.select_input(1, "merge-base")
    assert.are.equal(1, queries)
    assert.are.same({ "merge-base", "HEAD~1", "HEAD", "[ ] M a.txt +1 -1" }, h.lines(tab.bufnr))

    h.press("r")
    h.wait_for(function()
      return finished == 2
    end)
    assert.are.equal(2, queries)
    assert.are.same({ "merge-base", "HEAD~1", "HEAD", "[ ] M a.txt +1 -1" }, h.lines(tab.bufnr))
    assert.are.same({}, notes)
  end)

  it("prefills revision drafts and marks the current style in the select", function()
    local tab = h.open()
    h.edit_input(2, "HEAD~1")
    assert.are.equal("HEAD~1", h.input_opts(2).default)

    local format = h.select_format(1)
    assert.are.equal("direct [current]", format("direct"))
    assert.are.equal("merge-base", format("merge-base"))
    assert.are.same({ "direct", "HEAD~1", " " }, h.lines(tab.bufnr))
  end)

  it("redraws only the edited line and normalizes whitespace-only drafts", function()
    local tab = h.open()
    local ns = api.nvim_get_namespaces()["aviary.hawk.tab.label"]
    local marks = api.nvim_buf_get_extmarks(tab.bufnr, ns, 0, -1, { details = true })
    assert.are.equal("┌ old: ", marks[2][4].virt_text[1][1])
    assert.are.equal("└ new: ", marks[4][4].virt_text[1][1])
    local next_row = api.nvim_buf_get_extmarks(tab.bufnr, ns, { 2, 0 }, { 2, -1 }, {})

    h.edit_input(2, " HEAD~1 ")
    assert.are.same({ "direct", " HEAD~1 ", " " }, h.lines(tab.bufnr))
    h.edit_input(2)
    assert.are.same({ "direct", " HEAD~1 ", " " }, h.lines(tab.bufnr))
    h.edit_input(2, " \t\r\n")
    assert.are.same({ "direct", " ", " " }, h.lines(tab.bufnr))
    assert.are.same(next_row, api.nvim_buf_get_extmarks(tab.bufnr, ns, { 2, 0 }, { 2, -1 }, {}))
    assert.is_false(vim.bo[tab.bufnr].modified)
  end)

  it("warns outside Git without creating a tab", function()
    local tabs = api.nvim_list_tabpages()
    other = vim.fn.tempname()
    vim.fn.mkdir(other)
    vim.cmd.cd(other)
    hawk.show()
    assert.are.same(tabs, api.nvim_list_tabpages())
    assert.are.equal(source, api.nvim_get_current_win())
    assert.are.equal(1, #notes)
    assert.are.equal(vim.log.levels.WARN, notes[1].level)
  end)

  it("leaves the previous result and preview available on bad input and can retry", function()
    local tab = h.open()
    h.edit_input(2, "HEAD~1")
    h.edit_input(3, "HEAD")
    h.press("r")
    h.wait_for(function()
      return api.nvim_buf_line_count(tab.bufnr) == 4
    end)
    local title = vim.fn.bufname(tab.bufnr)
    api.nvim_win_set_cursor(0, { 4, 0 })
    h.press("<CR>")
    h.wait_for(function()
      return h.lines(tab.new_buf)[1] == "new"
    end)
    for _, value in ipairs({ "::index", "::worktree" }) do
      local previous = #notes
      h.edit_input(3, value)
      h.press("r")
      h.wait_for(function()
        return #notes > previous
      end)
      assert.are.equal(vim.log.levels.ERROR, notes[#notes].level)
      assert.is_truthy(notes[#notes].message:find(value, 1, true))
      assert.is_nil(notes[#notes].message:find("stack traceback", 1, true))
      assert.are.same({ "direct", "HEAD~1", value, "[ ] M a.txt +1 -1" }, h.lines(tab.bufnr))
      assert.are.equal(title, vim.fn.bufname(tab.bufnr))
      assert.are.same({ "new" }, h.lines(tab.new_buf))
    end

    h.edit_input(3, "HEAD~1")
    h.press("r")
    h.wait_for(function()
      return api.nvim_buf_line_count(tab.bufnr) == 3
    end)
    assert.are.same({ "direct", "HEAD~1", "HEAD~1" }, h.lines(tab.bufnr))
    assert.are.same({ "new" }, h.lines(tab.new_buf))
  end)

  it("opens previews at the first change", function()
    h.write(dir, "a.txt", { "one", "two", "three" })
    h.commit(dir)
    h.write(dir, "a.txt", { "one", "TWO", "three" })
    h.commit(dir)
    local tab, bottom = h.open()
    h.edit_input(2, "HEAD~1")
    h.edit_input(3, "HEAD")
    h.press("r")
    h.wait_for(function()
      return api.nvim_buf_line_count(tab.bufnr) == 4
    end)
    api.nvim_win_set_cursor(0, { 4, 0 })
    h.press("<CR>")
    h.wait_for(function()
      return h.lines(tab.new_buf)[2] == "TWO"
    end)
    assert.are.same({ 2, 0 }, api.nvim_win_get_cursor(tab.old_win))
    assert.are.same({ 2, 0 }, api.nvim_win_get_cursor(tab.new_win))
    assert.are.equal(bottom, api.nvim_get_current_win())
  end)

  it("keeps previews at line one when a change has no content hunks", function()
    h.git(dir, { "update-index", "--chmod=+x", "a.txt" })
    h.git(dir, { "commit", "-qm", "mode" })
    local tab = h.open()
    h.edit_input(2, "HEAD~1")
    h.edit_input(3, "HEAD")
    h.press("r")
    h.wait_for(function()
      return api.nvim_buf_line_count(tab.bufnr) == 4
    end)
    api.nvim_win_set_cursor(0, { 4, 0 })
    h.press("<CR>")
    h.wait_for(function()
      return h.lines(tab.new_buf)[1] == "new"
    end)
    assert.are.same({ 1, 0 }, api.nvim_win_get_cursor(tab.old_win))
    assert.are.same({ 1, 0 }, api.nvim_win_get_cursor(tab.new_win))
    assert.are.same({}, notes)
  end)

  it("keeps simultaneous reviews pinned across global cwd changes", function()
    local first, first_win = h.open()
    h.edit_input(2, "HEAD~1")
    h.edit_input(3, "HEAD")

    other = h.repo()
    h.write(other, "b.txt", { "B" })
    h.commit(other)
    h.write(other, "b.txt", { "new B" })
    h.commit(other)
    vim.cmd.cd(other)
    local second = h.open()
    h.edit_input(2, "HEAD~1")
    h.edit_input(3, "HEAD")
    h.press("r")
    h.wait_for(function()
      return api.nvim_buf_line_count(second.bufnr) == 4
    end)
    assert.are.same({ "direct", "HEAD~1", "HEAD", "[ ] M b.txt +1 -1" }, h.lines(second.bufnr))
    assert.are.same({ "direct", "HEAD~1", "HEAD" }, h.lines(first.bufnr))

    api.nvim_set_current_win(first_win)
    h.press("r")
    h.wait_for(function()
      return api.nvim_buf_line_count(first.bufnr) == 4
    end)
    assert.are.same({ "direct", "HEAD~1", "HEAD", "[ ] M a.txt +1 -1" }, h.lines(first.bufnr))
    assert.are.same({ "direct", "HEAD~1", "HEAD", "[ ] M b.txt +1 -1" }, h.lines(second.bufnr))
  end)

  it("keeps preview names distinct and stable when review tabs are renumbered", function()
    local reviews, names = {}, {}
    for index = 1, 2 do
      local tab, bottom = h.open()
      h.edit_input(2, "HEAD~1")
      h.edit_input(3, "HEAD")
      h.press("r")
      h.wait_for(function()
        return api.nvim_buf_line_count(tab.bufnr) == 4
      end)
      api.nvim_win_set_cursor(bottom, { 4, 0 })
      h.press("<CR>")
      h.wait_for(function()
        return h.lines(tab.new_buf)[1] == "new"
      end)
      assert.are.equal(bottom, api.nvim_get_current_win())
      reviews[index] = tab
      names[index] = api.nvim_buf_get_name(tab.new_buf)
      assert.matches(("%d:new/a%%.txt$"):format(tab.tabpage), names[index])
    end
    assert.are_not.equal(names[1], names[2])
    local first, second = reviews[1], reviews[2]
    local number = api.nvim_tabpage_get_number(second.tabpage)
    first:close()
    h.flush()
    assert.is_false(api.nvim_tabpage_is_valid(first.tabpage))
    assert.are.equal(number - 1, api.nvim_tabpage_get_number(second.tabpage))
    assert.are.equal(names[2], api.nvim_buf_get_name(second.new_buf))
    assert.are.same({}, notes)
  end)
end)
