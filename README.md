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
- Pigeon ships no picker dependency. Its built-in `buffers` action uses
  `vim.ui.select`; add a
  [files action](./docs/pigeon.md#files-action) for whichever picker you use.

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
        buffers = { "<C-b>" }, -- optional: send a listed buffer's path
        close = { "<C-.>" },
        pick = { "<F5>" }, -- optional: switch the Terminal's Agent
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

See the feature manuals above, or `:h hawk.nvim` and `:h pigeon.nvim`.
`pigeon.show()` reopens or focuses this editor's Terminal and chooses an Agent
when none is attached. `<C-.>` hides it while the Agent keeps running. The
built-in `pick` action switches the Terminal's Agent; bind it in
`pigeon.keymaps`. `show()` captures the current file and cursor line, or the
active Visual range, for Terminal actions. Each Neovim attaches its own client
directly to the chosen Agent session; actions deliver through the Agent that
client displays. Agent exit closes attached Terminals naturally. See
[agents and display](./docs/pigeon.md#agents-and-display) for terminal and tmux
behavior. Failed requests warn once and are never automatically replayed.

Root setup accepts a table of overrides for each named public feature. Each
call rebuilds those features from defaults and the supplied overrides.
Previously root-configured features omitted from the call also reset to
defaults. `setup()` and `setup({})` reset all such features. Features never
configured through root are left untouched. Calling `aviary.<feature>.setup(opts)`
directly rebuilds only that feature. Modules load lazily by name. Use the
option names, types and values documented for each feature. Setup acquires no
runtime resources.

## Workflows

[Hawk](./docs/hawk.md) opens a new Git Review tab for the global cwd's worktree.

```lua
require("aviary").hawk.show()
```

Press Enter to edit the `old` and `new` revisions or select the comparison
style (`direct` or `merge-base`), then press `r` to populate the list. Enter on
a change previews it in Neovim diff. Press `x` on a change to toggle its read
mark, or `X` to toggle all read marks. Each tab keeps its own worktree and
results. See the [Hawk manual](./docs/hawk.md#review) for details.

[Pigeon actions](./docs/pigeon.md#actions) run from the Terminal and receive a
lazy current-Agent getter and the captured reference. Bind the built-in `prompt`,
`pick` and `buffers` actions in `pigeon.keymaps`, then open Pigeon from a source
file window:

```lua
require("aviary").pigeon.show()
-- In the Terminal, press the prompt keymap to send a template about that reference,
-- the pick keymap to switch Agents, or the buffers keymap to send a buffer path.
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
the cursor line. Cancellation sends nothing.

Pigeon has a built-in `buffers` action that uses `vim.ui.select`, and no picker
dependency. Add a `files` action for your picker; see the
[files action example](./docs/pigeon.md#files-action).

## Default Options

<details>
<summary>Default Options</summary>

```lua
require("aviary").setup({
  hawk = {
    keymaps = {
      close = { "q" }, hawk = { "<CR>" }, refresh = { "r" },
      toggle_all = { "X" }, toggle_check = { "x" },
    },
    actions = {}, -- handlers receive the owning Review Tab
  },
  pigeon = {
    tools = {
      codex = { command = { "codex" } }, -- uses the default formatter
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
    actions = {}, -- built-in buffers, close, pick and prompt; user handlers merge
    prompts = { ["{file}"] = "{file} ", ["{line}"] = "{line} " },
    resolvers = {}, -- merges over the built-in file and line resolvers
    view = { width = 0.9, height = 0.9, border = "rounded" },
  },
})
```

</details>

## License

MIT
