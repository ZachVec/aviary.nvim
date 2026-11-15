---@module 'luassert'

describe("aviary.hawk.health", function()
  it("is reachable as :checkhealth aviary.hawk", function()
    local source, report = vim.api.nvim_get_current_buf(), nil
    local ok, err = pcall(function()
      vim.cmd("checkhealth aviary.hawk")
      report = vim.api.nvim_get_current_buf()
      local text = table.concat(vim.api.nvim_buf_get_lines(report, 0, -1, false), "\n")
      assert.is_truthy(text:find("git:", 1, true) or text:find("Git is required for Review", 1, true))
    end)
    if report and report ~= source then
      vim.api.nvim_buf_delete(report, { force = true })
    end
    vim.api.nvim_set_current_buf(source)
    assert(ok, tostring(err))
  end)
end)
