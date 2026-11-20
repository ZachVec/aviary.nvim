# aviary.nvim

Review Git changes and send references or prompts to agents displayed in Neovim.

| Feature | Use it for |
| --- | --- |
| [hawk](./docs/hawk.md) | Review Git versions. |
| [pigeon](./docs/pigeon.md) | Create agents, display a Terminal, and run actions that send references or prompts. |

## Requirements

<!-- vimdoc: pigeon.nvim-requirements -->

- Neovim 0.11+; Git for Review.
- Pigeon: tmux 3.8+; Neovim must run inside tmux on the default socket.
- An installed agent CLI, such as Codex or Claude, to create its tool instance.
- Pigeon ships no picker dependency. Add your own
  [files and buffers actions](./docs/pigeon.md#files-and-buffers-actions) for
  whichever picker you use.

## Installation

<!-- vimdoc: pigeon.nvim-installation -->

Install with lazy.nvim:

```lua
{
  "ZachVec/aviary.nvim",
  main = "aviary",
  opts = {
    pigeon = {
      keymaps = {
        close = { "<C-.>" },
        prompt = { "<C-p>" }, -- optional: open the prompt template menu
      },
    },
  },
  keys = {
    { "<leader>ar", function() require("aviary").hawk.show() end, desc = "Review changes" },
    { "<leader>ap", function() require("aviary").pigeon.show() end, desc = "Show agent" },
  },
}
```

See the feature manuals above, or `:h hawk.nvim` and `:h pigeon.nvim`. Use
`pigeon.pick()` to choose an Agent or create a tool instance; `pigeon.show()`
reopens or focuses this editor's Terminal and picks when no Agent is attached.
`<C-.>` hides it while the Agent keeps running. `show()` and `pick()` capture the
current file and cursor line, or the active Visual range, for Terminal actions.
Each Neovim attaches its own client directly to the chosen Agent session; actions
deliver through that Terminal's current Agent. Agent exit closes attached
Terminals naturally. See [agents and display](./docs/pigeon.md#agents-and-display)
for terminal and tmux behavior. Failed requests warn once and are never
automatically replayed.

Root setup accepts public feature names; nested tables belong to their feature.
Each call rebuilds from feature defaults and the current options. Previously
root-configured features omitted from the call also reset to defaults;
`setup()` and `setup({})` reset all such features. Features never configured
through root are left untouched. Calling `aviary.<feature>.setup(opts)` directly
rebuilds only that feature. Modules load lazily by name. Setup validates data and
acquires no runtime resources.

## Workflows

[Pigeon actions](./docs/pigeon.md#actions) run from the Terminal and receive the
current Agent and captured reference. The built-in `prompt` action selects a
named template and sends it; bind it in `pigeon.keymaps`. [Hawk](./docs/hawk.md)
opens Git Review:

```lua
local aviary = require("aviary")
aviary.hawk.show()   -- inspect changed files and two Git versions
aviary.pigeon.show() -- show/create the Terminal; captures the current reference
-- In the Terminal, press the prompt keymap to send a template about that reference.
```

The reference is the current file and cursor line, or the Visual whole-line range
when `show()` is invoked from Visual mode. Bind `show()` for Normal and Visual
modes with a Lua callback mapping so Visual remains active until capture:

```lua
vim.keymap.set({ "n", "x" }, "<leader>ap", function()
  require("aviary").pigeon.show()
end)
```

`x` is Visual-only; `v` would also bind Select mode, where Pigeon captures only
the cursor line. Cancellation sends nothing. `hawk.show()` opens or focuses its
single reusable Review tab. Review defaults to HEAD → index, following HEAD on
refresh; Enter displays the selected file's captured versions in native diff.
b/B and f/F choose refs/commits, and t toggles merge-base comparison. Creation
errors propagate after rollback. Asynchronous Review failures report once and
leave the UI available for retry.

Pigeon has no built-in files/buffers actions and no picker dependency. Add an
action for your picker; see the
[files and buffers example](./docs/pigeon.md#files-and-buffers-actions).

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
    keymaps = { close = { "<C-.>" } },
    actions = {}, -- built-in close and prompt; user handlers merge
    prompts = { ["{file}"] = "{file} ", ["{line}"] = "{line} " },
    resolvers = {}, -- merges over the built-in file and line resolvers
    view = { width = 0.9, height = 0.9, border = "rounded" },
  },
})
```

</details>

## License

MIT
