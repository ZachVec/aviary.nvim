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
    assert.are.same({ " ", " " }, h.lines(tab.bufnr))
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
    h.edit_input(1, "HEAD~1")
    h.press("r")
    h.edit_input(2, "HEAD")
    assert.are.equal(0, queries)
    assert.are.same({ "HEAD~1", "HEAD" }, h.lines(tab.bufnr))

    h.press("r")
    h.wait_for(function()
      return api.nvim_buf_line_count(tab.bufnr) == 3
    end)
    assert.are.equal(1, queries)
    assert.are.same({ "HEAD~1", "HEAD", "  M a.txt +1 -1" }, h.lines(tab.bufnr))
    assert.matches("HEAD~1", vim.fn.bufname(tab.bufnr))
  end)

  it("switches through custom actions, keeping drafts and waiting for another refresh", function()
    local queries = 0
    Git.diff = function(...)
      queries = queries + 1
      return diff(...)
    end
    assert(Config.setup({
      keymaps = { merge = { "<F7>" }, direct = { "<F8>" } },
      actions = {
        merge = function(tab)
          tab:to("merge")
        end,
        direct = function(tab)
          tab:to("direct")
        end,
      },
    }))
    local tab = h.open()
    assert.are.same({}, vim.fn.maparg("t", "n", false, true))
    h.edit_input(1, "HEAD~1")
    h.edit_input(2, "HEAD")
    h.press("r")
    h.wait_for(function()
      return api.nvim_buf_line_count(tab.bufnr) == 3
    end)
    local tick = api.nvim_buf_get_changedtick(tab.bufnr)
    h.press("<F8>")
    assert.are.equal(tick, api.nvim_buf_get_changedtick(tab.bufnr))
    h.press("<F7>")
    assert.are.same({ "HEAD~1", "HEAD" }, h.lines(tab.bufnr))
    assert.matches("󰓁$", vim.fn.bufname(tab.bufnr))
    assert.are.equal(1, queries)

    h.edit_input(1, "HEAD")
    h.press("r")
    h.wait_for(function()
      return vim.fn.bufname(tab.bufnr):find("HEAD", 1, true) ~= nil
    end)
    assert.are.equal(2, queries)
    assert.are.same({ "HEAD", "HEAD" }, h.lines(tab.bufnr))
    assert.are.same({}, notes)
  end)

  it("redraws only the edited line and normalizes whitespace-only drafts", function()
    local tab = h.open()
    local ns = api.nvim_get_namespaces()["aviary.hawk.tab.label"]
    local marks = api.nvim_buf_get_extmarks(tab.bufnr, ns, 0, -1, { details = true })
    assert.are.equal("← old: ", marks[1][4].virt_text[1][1])
    assert.are.equal("→ new: ", marks[3][4].virt_text[1][1])
    local next_row = api.nvim_buf_get_extmarks(tab.bufnr, ns, { 1, 0 }, { 1, -1 }, {})

    h.edit_input(1, " HEAD~1 ")
    assert.are.same({ " HEAD~1 ", " " }, h.lines(tab.bufnr))
    h.edit_input(1)
    assert.are.same({ " HEAD~1 ", " " }, h.lines(tab.bufnr))
    h.edit_input(1, " \t\r\n")
    assert.are.same({ " ", " " }, h.lines(tab.bufnr))
    assert.are.same(next_row, api.nvim_buf_get_extmarks(tab.bufnr, ns, { 1, 0 }, { 1, -1 }, {}))
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
    h.edit_input(1, "HEAD~1")
    h.edit_input(2, "HEAD")
    h.press("r")
    h.wait_for(function()
      return api.nvim_buf_line_count(tab.bufnr) == 3
    end)
    local title = vim.fn.bufname(tab.bufnr)
    api.nvim_win_set_cursor(0, { 3, 0 })
    h.press("<CR>")
    h.wait_for(function()
      return h.lines(tab.new_buf)[1] == "new"
    end)
    for _, value in ipairs({ "::index", "::worktree" }) do
      local previous = #notes
      h.edit_input(2, value)
      h.press("r")
      h.wait_for(function()
        return #notes > previous
      end)
      assert.are.equal(vim.log.levels.ERROR, notes[#notes].level)
      assert.is_truthy(notes[#notes].message:find(value, 1, true))
      assert.is_nil(notes[#notes].message:find("stack traceback", 1, true))
      assert.are.same({ "HEAD~1", value, "  M a.txt +1 -1" }, h.lines(tab.bufnr))
      assert.are.equal(title, vim.fn.bufname(tab.bufnr))
      assert.are.same({ "new" }, h.lines(tab.new_buf))
    end

    h.edit_input(2, "HEAD~1")
    h.press("r")
    h.wait_for(function()
      return api.nvim_buf_line_count(tab.bufnr) == 2
    end)
    assert.are.same({ "HEAD~1", "HEAD~1" }, h.lines(tab.bufnr))
    assert.are.same({ "new" }, h.lines(tab.new_buf))
  end)

  it("keeps simultaneous reviews pinned across global cwd changes", function()
    local first, first_win = h.open()
    h.edit_input(1, "HEAD~1")
    h.edit_input(2, "HEAD")

    other = h.repo()
    h.write(other, "b.txt", { "B" })
    h.commit(other)
    h.write(other, "b.txt", { "new B" })
    h.commit(other)
    vim.cmd.cd(other)
    local second = h.open()
    h.edit_input(1, "HEAD~1")
    h.edit_input(2, "HEAD")
    h.press("r")
    h.wait_for(function()
      return api.nvim_buf_line_count(second.bufnr) == 3
    end)
    assert.are.same({ "HEAD~1", "HEAD", "  M b.txt +1 -1" }, h.lines(second.bufnr))
    assert.are.same({ "HEAD~1", "HEAD" }, h.lines(first.bufnr))

    api.nvim_set_current_win(first_win)
    h.press("r")
    h.wait_for(function()
      return api.nvim_buf_line_count(first.bufnr) == 3
    end)
    assert.are.same({ "HEAD~1", "HEAD", "  M a.txt +1 -1" }, h.lines(first.bufnr))
    assert.are.same({ "HEAD~1", "HEAD", "  M b.txt +1 -1" }, h.lines(second.bufnr))
  end)

  it("keeps preview names distinct and stable when review tabs are renumbered", function()
    local reviews, names = {}, {}
    for index = 1, 2 do
      local tab, bottom = h.open()
      h.edit_input(1, "HEAD~1")
      h.edit_input(2, "HEAD")
      h.press("r")
      h.wait_for(function()
        return api.nvim_buf_line_count(tab.bufnr) == 3
      end)
      api.nvim_win_set_cursor(bottom, { 3, 0 })
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
