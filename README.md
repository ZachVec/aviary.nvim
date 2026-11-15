# aviary.nvim

Review Git changes and send references or text to the clipboard or tmux.

| Feature | Use it for |
| --- | --- |
| [hawk](./docs/hawk.md) | Review Git versions. |
| [weaver](./docs/weaver.md) | Capture templates, file/buffer and line references, and selected text. |
| [pigeon](./docs/pigeon.md) | Create and select receivers, display them, and deliver Messages. |

## Requirements

<!-- vimdoc: pigeon.nvim-requirements -->

- Neovim 0.11+; Git for Review.
- A working Neovim clipboard provider for clipboard exports.
- Optional: tmux 3.8+ for native floating tool views; Neovim must run inside an
  existing tmux server.
- `weaver.files()` and `weaver.buffers()` require [snacks.nvim](https://github.com/folke/snacks.nvim)
  or [fzf-lua](https://github.com/ibhagwan/fzf-lua). Other choices use `vim.ui.select`.

## Installation

<!-- vimdoc: pigeon.nvim-installation -->

Install with lazy.nvim:

```lua
{
  "ZachVec/aviary.nvim",
  main = "aviary",
  opts = {
    weaver = { picker = "snacks" }, -- snacks | fzf-lua; files/buffers only
    pigeon = { backend = { default = "clipboard" } }, -- clipboard | tmux
  },
  keys = {
    { "<leader>ar", function() require("aviary").hawk.show() end, desc = "Review changes" },
    { "<leader>ac", function() require("aviary").weaver.prompt() end, mode = { "n", "x" }, desc = "Choose prompt" },
    { "<leader>af", function() require("aviary").weaver.files() end, desc = "Send file references" },
    { "<leader>ap", function() require("aviary").pigeon.show() end, desc = "Show receiver" },
  },
}
```

See the feature manuals above, or `:h hawk.nvim`, `:h weaver.nvim` and
`:h pigeon.nvim`. [Receiver settings](./docs/pigeon.md#exporting-and-selection)
apply to every Message passed to Pigeon. Use `pigeon.pick()` to choose and display
a new tool or an existing target on the default backend. For floating tool views, set
`pigeon.backend.default = "tmux"` and call `pigeon.show()`; without a current
target it opens the same picker first. Receivers and views use Neovim's tmux server.
Renaming a receiver window does not affect discovery. `C-.` returns to Neovim with
the tool still running.
Creation, evaluation, display and delivery failures warn and clear current. The
next explicit action selects again. Use `pigeon.pick()` to switch explicitly; failed requests
are never automatically replayed.

Root setup accepts public feature names; nested tables belong to their feature.
Each call rebuilds from feature defaults and the current options. Previously
root-configured features omitted from the call also reset to defaults;
`setup()` and `setup({})` reset all such features. Features never configured
through root are left untouched. Calling `aviary.<feature>.setup(opts)` directly
rebuilds only that feature. Modules load lazily by name. Setup validates data and
acquires no runtime resources.

## Workflows

[Weaver actions](./docs/weaver.md#usage) capture content and send it through
Pigeon's current/default target; [Hawk](./docs/hawk.md) opens Git Review:

```lua
local aviary = require("aviary")
aviary.weaver.prompt()  -- choose a template; {line} uses the cursor line or Visual range
aviary.weaver.files()   -- choose file references and send them
aviary.weaver.buffers() -- choose buffer references and send them
aviary.weaver.text()    -- send the active Visual lines or cursor line
aviary.hawk.show()      -- inspect changed files and two Git versions
```

All actions take no arguments and return nothing. Text capture
delivers immediately; selectors deliver after confirmation. Prompt context,
including any Visual range, is captured before template selection. Resuming
a file/buffer picker can send again. Cancellation sends nothing. `hawk.show()`
opens or focuses its single reusable Review tab.
Review defaults to HEAD → index, following HEAD on refresh;
Enter displays the selected file's captured versions in native diff. b/B and f/F
choose refs/commits, and t toggles merge-base comparison. Creation errors
propagate after rollback. Asynchronous Review failures report once and leave the
UI available for retry.

Choose the `{line}` prompt for the current file and cursor line or Visual range.
This replaces the former Hawk comment action; there is no comment input or stored
comment list. Setup configuration stays under feature names.

## Default Options

<details>
<summary>Default Options</summary>

```lua
require("aviary").setup({
  hawk = {
    keymaps = {
      close = { "q" }, refresh = { "r" }, jump = { "<CR>" },
      base_ref = { "b" }, base_commit = { "B" },
      target_ref = { "f" }, target_commit = { "F" }, toggle = { "t" },
    },
    actions = {}, -- handlers receive the owning Review Tab
  },
  weaver = {
    picker = "snacks",
    prompts = { ["{file}"] = "{file} ", ["{line}"] = "{line} " },
    resolvers = {}, -- merges over built-in file/line resolvers
    references = { join = "\n" },
  },
  pigeon = {
    format = function(path, first, last)
      if not first then return path end
      return path .. " :L" .. first .. (last and last ~= first and "-" .. last or "")
    end,
    tools = {
      codex = { command = { "codex" } }, -- uses pigeon.format
      claude = {
        command = { "claude" },
        format = function(path, first, last)
          local mention = path:find("[^%w/_%.%-]") and ('"' .. path .. '"') or path
          return "@" .. mention .. (first and "#L" .. first or "")
            .. (first and last and last ~= first and "-" .. last or "")
        end,
      },
    },
    backend = {
      default = "clipboard",
      tmux = { width = "90%", height = "90%", close = "C-." },
    },
  },
})
```

</details>

## License

MIT
