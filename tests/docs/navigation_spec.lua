---@module 'luassert'

local root = vim.uv.cwd()

describe("generated Vimdoc navigation", function()
  local dir

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/doc", "p")
    for _, path in ipairs(vim.fn.glob(root .. "/doc/*.nvim.txt", false, true)) do
      vim.fn.writefile(vim.fn.readfile(path), dir .. "/doc/" .. vim.fs.basename(path))
    end
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  --- Exercise real help commands with an isolated runtime and generated tags.
  local function check(body)
    local setup = ([=[
vim.opt.runtimepath:prepend(%q)
vim.cmd.helptags(%q)

local function open(tag, file)
  vim.cmd.help(tag)
  assert(vim.fs.basename(vim.api.nvim_buf_get_name(0)) == file)
end

local function follow(tag, file)
  assert(vim.fn.search("\\V|" .. tag .. "|", "w") > 0, "missing link: " .. tag)
  vim.cmd.normal({ args = { vim.keycode("<C-]>") }, bang = true })
  assert(vim.fs.basename(vim.api.nvim_buf_get_name(0)) == file)
end

local function section()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return table.concat(vim.api.nvim_buf_get_lines(0, row - 1, math.min(row + 25, vim.api.nvim_buf_line_count(0)), false), "\n")
end
]=]):format(dir, dir .. "/doc")
    local script = dir .. "/check.lua"
    vim.fn.writefile(vim.split(setup .. body, "\n"), script)
    local result = vim
      .system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", script }, { text = true })
      :wait(10000)
    assert.are.equal(0, result.code, result.stderr)
  end

  it("jumps from feature manuals to the README's installation and requirements", function()
    check([=[
open("hawk.nvim", "hawk.nvim.txt")
follow("aviary.nvim-installation", "aviary.nvim.txt")
assert(section():find("ZachVec/aviary.nvim", 1, true))
open("pigeon.nvim", "pigeon.nvim.txt")
follow("aviary.nvim-installation", "aviary.nvim.txt")
assert(section():find("ZachVec/aviary.nvim", 1, true))
open("pigeon.nvim", "pigeon.nvim.txt")
follow("aviary.nvim-requirements", "aviary.nvim.txt")
assert(section():find("Neovim 0.11+", 1, true))
]=])
  end)

  it("jumps from the README to feature manuals and shared user settings", function()
    check([=[
open("aviary.nvim", "aviary.nvim.txt")
follow("hawk.nvim", "hawk.nvim.txt")
open("aviary.nvim", "aviary.nvim.txt")
follow("pigeon.nvim", "pigeon.nvim.txt")
open("aviary.nvim", "aviary.nvim.txt")
follow("pigeon.nvim-exporting-and-selection", "pigeon.nvim.txt")
assert(section():find("tool", 1, true))
]=])
  end)

  it("keeps legacy installation and requirements tags beside their content", function()
    check([=[
open("pigeon.nvim-installation", "aviary.nvim.txt")
assert(section():find("ZachVec/aviary.nvim", 1, true))
open("pigeon.nvim-requirements", "aviary.nvim.txt")
assert(section():find("Neovim 0.11+", 1, true))
assert(section():find("tmux 3.8+", 1, true))
]=])
  end)
end)
