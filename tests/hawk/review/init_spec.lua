---@module 'luassert'

local hawk = require("aviary").hawk
local Config = require("aviary.hawk.config")
local Path = require("aviary.shared.path")
local Review = require("aviary.hawk.review.review")
local h = require("hawk.helpers")

local function wait_for(predicate)
  assert(vim.wait(5000, predicate, 10), "Hawk operation did not complete")
end
local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end
local function ready()
  wait_for(function()
    return vim.bo.filetype == "aviary_hawk" and vim.fn.bufname() ~= ""
  end)
end

-- These specs cross the public entry: native tabs/diff, real Git and configured
-- actions. show owns instance reuse; ReviewTab owns scheduling and rendering.
describe("Hawk Review UI", function()
  local dir, cwd, source, input, select_ui, notify, notes, read_text
  before_each(function()
    source, cwd = vim.api.nvim_get_current_win(), Path.cwd()
    input, select_ui, notify = vim.ui.input, vim.ui.select, vim.notify
    read_text = Review.text
    notes = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(message)
      notes[#notes + 1] = message
    end
    dir = h.repo()
    h.write(dir, "a.txt", { "old" })
    h.write(dir, "b.txt", { "other" })
    h.commit(dir)
    h.write(dir, "a.txt", { "staged" })
    h.git(dir, { "add", "a.txt" })
    vim.cmd.cd(dir)
    h.edit(dir .. "/a.txt")
    Config.setup()
  end)
  after_each(function()
    Review.text = read_text
    vim.ui.input, vim.ui.select = input, select_ui
    h.cleanup(source, dir)
    h.flush()
    vim.cmd.cd(cwd)
    Config.setup()
    vim.notify = notify
  end)

  it("keeps metadata on tab entry and focus until explicitly refreshed", function()
    local start, read = Review.start, Review.read
    local reads = 0
    ---@diagnostic disable-next-line: duplicate-set-field
    Review.start = function()
      return function() end
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    Review.read = function(...)
      reads = reads + 1
      return read(...)
    end
    local ok, reason = pcall(function()
      hawk.show()
      ready()
      assert.are.equal("Review:  HEAD   index", vim.fn.bufname())
      local review_tab = vim.api.nvim_get_current_tabpage()
      local previous = reads
      vim.api.nvim_set_current_win(source)
      vim.api.nvim_exec_autocmds("FocusGained", {})
      h.flush()
      assert.are.equal(previous, reads)
      vim.api.nvim_set_current_tabpage(review_tab)
      vim.api.nvim_exec_autocmds("FocusGained", {})
      h.flush()
      assert.are.equal(previous, reads)
      h.press("r")
      wait_for(function()
        return reads == previous + 1
      end)
    end)
    Review.start, Review.read = start, read
    assert(ok, reason)
  end)

  it("opens and refreshes empty outside Git, reports version selection errors and recovers on entering Git", function()
    local outside = vim.fn.tempname()
    vim.fn.mkdir(outside, "p")
    vim.cmd.cd(outside)
    local selections = 0
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function()
      selections = selections + 1
    end
    local ok, reason = pcall(function()
      hawk.show()
      ready()
      local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
      assert.are.equal("Review", vim.fn.bufname(buf))
      for _, pane in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        assert.are.same({ "" }, lines(vim.api.nvim_win_get_buf(pane)))
      end
      h.press("r")
      h.press("<CR>")
      assert.are.equal(win, vim.api.nvim_get_current_win())
      assert.are.same({}, notes)
      for index, key in ipairs({ "b", "B", "f", "F" }) do
        h.press(key)
        assert.are.equal(index, #notes)
        assert.matches("not a Git worktree", notes[index])
      end
      assert.are.equal(0, selections)
      vim.cmd.cd(dir)
      wait_for(function()
        return lines(buf)[1]:find("a.txt", 1, true) ~= nil
      end)
      assert.are.equal(4, #notes)
    end)
    vim.cmd.cd(dir)
    vim.fn.delete(outside, "rf")
    assert(ok, reason)
  end)

  it("discovers a repository initialized in the same cwd on manual refresh", function()
    vim.fn.delete(dir .. "/.git", "rf")
    hawk.show()
    ready()
    local buf = vim.api.nvim_get_current_buf()
    assert.are.equal("Review", vim.fn.bufname(buf))
    h.git(dir, { "init", "-q", "-b", "main" })
    h.git(dir, { "config", "user.email", "test@example.com" })
    h.git(dir, { "config", "user.name", "test" })
    h.commit(dir)
    h.write(dir, "a.txt", { "initialized" })
    h.git(dir, { "add", "a.txt" })
    h.press("r")
    wait_for(function()
      return lines(buf)[1]:find("a.txt", 1, true) ~= nil
    end)
    assert.are.equal(dir, Path.cwd())
    assert.are.same({}, notes)
  end)

  it("reuses Review directly and preserves ordinary source buffers on closure", function()
    local source_buf = vim.api.nvim_get_current_buf()
    require("aviary").hawk.show()
    ready()
    local review_tab, review_buf, review_win =
      vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    assert.are.equal(3, #vim.api.nvim_tabpage_list_wins(review_tab))
    assert.is_true(vim.wo.winfixbuf)
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function()
      error("opening Review must not select a feature")
    end
    assert.are_not.equal(1, vim.fn.maparg("<Tab>", "n", false, true).buffer)
    hawk.show()
    assert.are.equal(review_tab, vim.api.nvim_get_current_tabpage())
    assert.are.equal(review_win, vim.api.nvim_get_current_win())
    assert.are.equal(review_buf, vim.api.nvim_get_current_buf())
    vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "unsaved" })
    vim.api.nvim_set_current_win(source)
    hawk.show()
    assert.are.equal(review_tab, vim.api.nvim_get_current_tabpage())
    assert.are.equal(review_buf, vim.api.nvim_get_current_buf())
    h.press("q")
    hawk.show()
    local replacement = vim.api.nvim_get_current_tabpage()
    assert.are_not.equal(review_tab, replacement)
    ready()
    h.flush()
    assert.is_false(vim.api.nvim_tabpage_is_valid(review_tab))
    assert.is_false(vim.api.nvim_buf_is_valid(review_buf))
    assert.is_true(vim.api.nvim_buf_is_valid(source_buf))
    assert.are.same({ "unsaved" }, lines(source_buf))
    hawk.show()
    assert.are.equal(replacement, vim.api.nvim_get_current_tabpage())
  end)

  it("reuses two locked readonly buffers and reads fixed index objects on Enter", function()
    hawk.show()
    ready()
    local navigation = vim.api.nvim_get_current_win()
    local tab = vim.api.nvim_get_current_tabpage()
    local body = vim.tbl_filter(function(win)
      return win ~= navigation
    end, vim.api.nvim_tabpage_list_wins(tab))
    table.sort(body, function(a, b)
      return vim.api.nvim_win_get_position(a)[2] < vim.api.nvim_win_get_position(b)[2]
    end)
    local old_buf, new_buf = vim.api.nvim_win_get_buf(body[1]), vim.api.nvim_win_get_buf(body[2])
    h.write(dir, "a.txt", { "later index" })
    h.git(dir, { "add", "a.txt" })
    -- Press before the debounced watcher replaces the represented metadata.
    h.press("<CR>")
    assert.are.equal(body[2], vim.api.nvim_get_current_win())
    wait_for(function()
      return lines(new_buf)[1] == "staged"
    end)
    assert.are.equal("HEAD://a.txt", vim.api.nvim_buf_get_name(old_buf))
    assert.are.equal("index://a.txt", vim.api.nvim_buf_get_name(new_buf))
    assert.are.same({ "old" }, lines(old_buf))
    assert.is_true(vim.wo[body[1]].diff and vim.wo[body[2]].diff)
    assert.is_true(vim.wo[body[1]].winfixbuf and vim.wo[body[2]].winfixbuf)
    assert.is_true(vim.bo[new_buf].readonly)
    assert.is_false(vim.bo[new_buf].modifiable)
    assert.has_error(function()
      vim.api.nvim_win_set_buf(body[2], vim.fn.bufnr(dir .. "/a.txt"))
    end)
    h.git(dir, { "rm", "-f", "b.txt" })
    hawk.show()
    h.press("r")
    local feature_buf = vim.api.nvim_get_current_buf()
    wait_for(function()
      return #lines(feature_buf) == 2
    end)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    h.press("<CR>")
    wait_for(function()
      return lines(old_buf)[1] == "other"
    end)
    assert.are.equal(body[2], vim.api.nvim_get_current_win())
    assert.are.same({ "" }, lines(new_buf))
    assert.are.equal("HEAD://b.txt", vim.api.nvim_buf_get_name(old_buf))
    assert.are.equal("index://b.txt", vim.api.nvim_buf_get_name(new_buf))
    assert.are.equal(old_buf, vim.api.nvim_win_get_buf(body[1]))
    assert.are.equal(new_buf, vim.api.nvim_win_get_buf(body[2]))
    hawk.show()
    h.press("q")
    h.flush()
    assert.is_false(vim.api.nvim_buf_is_valid(old_buf))
    assert.is_false(vim.api.nvim_buf_is_valid(new_buf))
  end)

  it("refreshes metadata as HEAD moves without replacing displayed versions", function()
    hawk.show()
    ready()
    local feature_buf = vim.api.nvim_get_current_buf()
    h.press("<CR>")
    local version = vim.api.nvim_get_current_buf()
    wait_for(function()
      return lines(version)[1] == "staged"
    end)
    h.write(dir, "b.txt", { "changed" })
    h.git(dir, { "add", "b.txt" })
    wait_for(function()
      return #lines(feature_buf) == 2
    end)
    assert.are.same({ "staged" }, lines(version))
    h.git(dir, { "reset", "-q", "HEAD", "a.txt" })
    wait_for(function()
      return #lines(feature_buf) == 1 and lines(feature_buf)[1]:find("b.txt", 1, true) ~= nil
    end)
    local initial = vim.trim(h.git(dir, { "rev-parse", "HEAD" }))
    h.commit(dir)
    hawk.show()
    h.press("r")
    wait_for(function()
      return vim.deep_equal({ "" }, lines(feature_buf))
    end)
    assert.are.equal("Review:  HEAD   index", vim.fn.bufname(feature_buf))
    assert.are.same({ "staged" }, lines(version))
    h.git(dir, { "checkout", "-qb", "side", initial })
    h.write(dir, "b.txt", { "side commit" })
    h.commit(dir)
    h.write(dir, "a.txt", { "side staged" })
    h.git(dir, { "add", "a.txt" })
    h.press("r")
    wait_for(function()
      return vim.deep_equal({ "M a.txt +1 -1" }, lines(feature_buf))
    end)
    assert.are.same({ "staged" }, lines(version))
    assert.are.same({}, notes)
  end)

  it("binds one action set to the same Review Tab before and after reading", function()
    local tab, count
    Config.setup({
      keymaps = { inspect = { "i", "I" }, refresh = {}, jump = { "o" } },
      actions = {
        inspect = function(...)
          count = select("#", ...)
          tab = ...
        end,
      },
    })
    hawk.show()
    assert.are_not.equal(1, vim.fn.maparg("r", "n", false, true).buffer)
    assert.are_not.equal(1, vim.fn.maparg("<CR>", "n", false, true).buffer)
    assert.is_function(vim.fn.maparg("o", "n", false, true).callback)
    vim.fn.maparg("i", "n", false, true).callback()
    assert.are.equal(1, count)
    assert.are.equal(vim.api.nvim_get_current_buf(), tab.bufnr)
    assert.is_nil(tab:current())
    local original = tab
    ready()
    h.press("I")
    assert.are.equal(1, count)
    assert.is_true(tab == original)
    assert.is_function(tab.jump)
    assert.is_function(tab.pick)
    assert.is_function(tab.toggle)
    local item = tab:current()
    assert(item)
    assert.are.equal("a.txt", item.path)
    assert.is_function(item.render)
  end)

  it("can repair a deleted ref even when reopening fails its first read", function()
    h.git(dir, { "branch", "temporary" })
    hawk.show()
    ready()
    local choices, choose
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, _, done)
      choices, choose = items, done
    end
    h.press("b")
    wait_for(function()
      return choices ~= nil
    end)
    for _, choice in ipairs(choices) do
      if choice.label == "refs/heads/temporary" then
        choose(choice)
      end
    end
    local buf = vim.api.nvim_get_current_buf()
    wait_for(function()
      return vim.api.nvim_buf_get_name(buf):find("refs/heads/temporary", 1, true) ~= nil
    end)
    h.press("q")
    h.flush()
    h.git(dir, { "branch", "-D", "temporary" })
    hawk.show()
    wait_for(function()
      return #notes > 0
    end)
    choices = nil
    h.press("b")
    wait_for(function()
      return choices ~= nil
    end)
    choose(assert(choices)[1]) -- refs/heads/main
    buf = vim.api.nvim_get_current_buf()
    wait_for(function()
      return vim.fn.bufname(buf) == "Review:  refs/heads/main   index"
    end)
  end)

  it("uses one ref/commit picker and displays comparison modes with short hashes and unchanged refs", function()
    hawk.show()
    ready()
    local choices, choose
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, _, done)
      choices, choose = items, done
    end
    h.press("f")
    wait_for(function()
      return choices ~= nil
    end)
    assert.are.equal("index", assert(choices)[1].revision)
    assert(choose)(assert(choices)[2]) -- refs/heads/main
    local buf = vim.api.nvim_get_current_buf()
    wait_for(function()
      return vim.fn.bufname(buf) == "Review:  refs/heads/main   refs/heads/main"
    end)
    assert.are.same({ "" }, lines(buf))
    h.press("t")
    wait_for(function()
      return vim.fn.bufname(buf) == "Review: 󰓁 refs/heads/main   refs/heads/main"
    end)
    choices = nil
    h.press("B")
    wait_for(function()
      return choices ~= nil
    end)
    local sha = vim.trim(h.git(dir, { "rev-parse", "HEAD" }))
    assert.are.equal(sha, assert(choices)[1].revision)
    choose(assert(choices)[1])
    wait_for(function()
      return vim.fn.bufname(buf) == "Review: 󰓁 " .. sha:sub(1, 7) .. "   refs/heads/main"
    end)
    choices = nil
    h.press("F")
    wait_for(function()
      return choices ~= nil
    end)
    assert.are.equal(sha, assert(choices)[1].revision)
    choose(assert(choices)[1])
    wait_for(function()
      return vim.fn.bufname(buf) == ("Review: 󰓁 %s   %s"):format(sha:sub(1, 7), sha:sub(1, 7))
    end)
    -- Restore choices via the same UI, so business context stays valid across tests.
    choices = nil
    h.press("b")
    wait_for(function()
      return choices ~= nil
    end)
    choose(assert(choices)[1])
    choices = nil
    h.press("f")
    wait_for(function()
      return choices ~= nil
    end)
    choose(assert(choices)[1])
    h.press("t")
    wait_for(function()
      return vim.fn.bufname(buf) == "Review:  refs/heads/main   index"
    end)
  end)
  it("applies a pending picker after closure without retaining its old UI", function()
    local choices, choose
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, _, done)
      choices, choose = items, done
    end
    hawk.show()
    ready()
    h.press("f")
    wait_for(function()
      return choices ~= nil
    end)
    h.press("q")
    h.flush()
    assert(choose)(assert(choices)[2])
    hawk.show()
    ready()
    local buf = vim.api.nvim_get_current_buf()
    assert.is_truthy(vim.fn.bufname(buf):find("  refs/heads/main", 1, true))
    assert.are.same({ "" }, lines(buf))
    choices = nil
    h.press("f")
    wait_for(function()
      return choices ~= nil
    end)
    choose(assert(choices)[1])
    wait_for(function()
      return vim.fn.bufname(buf):find("  index", 1, true) ~= nil
    end)
    assert.are.same({}, notes)
  end)

  it("clears the list outside Git, retains displayed versions and refreshes on return", function()
    local outside = vim.fn.tempname()
    vim.fn.mkdir(outside, "p")
    local ok, reason = pcall(function()
      hawk.show()
      ready()
      local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
      h.press("<CR>")
      local body = vim.api.nvim_get_current_buf()
      wait_for(function()
        return lines(body)[1] == "staged"
      end)
      vim.api.nvim_set_current_win(win)
      vim.cmd.cd(outside)
      wait_for(function()
        return vim.fn.bufname(buf) == "Review"
      end)
      assert.are.same({ "" }, lines(buf))
      assert.are.same({ "staged" }, lines(body))
      assert.are.equal(buf, vim.api.nvim_get_current_buf())
      h.press("<CR>")
      assert.are.equal(win, vim.api.nvim_get_current_win())
      vim.cmd.cd(dir)
      wait_for(function()
        return lines(buf)[1]:find("a.txt", 1, true) ~= nil
      end)
      assert.are.same({}, notes)
    end)
    vim.cmd.cd(dir)
    vim.fn.delete(outside, "rf")
    assert(ok, reason)
  end)

  it("ignores local cwd and rejects a picker captured before global repository change", function()
    local read = Review.read
    local choices, choose
    ---@type aviary.hawk.review.Context?
    local seen
    local other = h.repo()
    h.write(other, "a.txt", { "other repository" })
    h.commit(other)
    ---@diagnostic disable-next-line: duplicate-set-field
    Review.read = function(ctx, selection)
      local items, base = read(ctx, selection)
      seen = selection
      return items, base
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, _, done)
      choices, choose = items, done
    end
    local ok, reason = pcall(function()
      hawk.show()
      ready()
      vim.cmd.lcd(other .. "/.git")
      h.press("f")
      wait_for(function()
        return choices ~= nil
      end)
      assert.are.equal(dir, assert(seen).root)
      vim.cmd.cd(other)
      choose(choices[2])
      wait_for(function()
        return seen and seen.root == other
      end)
      assert.are.equal("index", assert(seen).target)
      h.press("q")
      h.flush()
      assert.are.same({}, notes)
    end)
    vim.api.nvim_set_current_win(source)
    vim.cmd.cd(dir)
    Review.read = read
    vim.fn.delete(other, "rf")
    assert(ok, reason)
  end)
end)
