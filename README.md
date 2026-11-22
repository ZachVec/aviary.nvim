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
        pick = { "<F5>" }, -- optional: switch the Terminal's Agent
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

Root setup accepts public feature names; nested tables belong to their feature.
Each call rebuilds from feature defaults and the current options. Previously
root-configured features omitted from the call also reset to defaults;
`setup()` and `setup({})` reset all such features. Features never configured
through root are left untouched. Calling `aviary.<feature>.setup(opts)` directly
rebuilds only that feature. Modules load lazily by name. Setup validates data and
acquires no runtime resources.

## Workflows

[Hawk](./docs/hawk.md) opens a new Git Review tab for the global cwd's worktree.

```lua
require("aviary").hawk.show()
```

Press Enter to edit the `old` and `new` revisions, then press `r` to populate
the list. Enter on a change previews it in Neovim diff. Press `x` on a change
to toggle its read mark. Each tab keeps its own worktree and results. See the
[Hawk manual](./docs/hawk.md#configuration) for bindings that select a comparison mode.

[Pigeon actions](./docs/pigeon.md#actions) run from the Terminal and receive a
lazy current-Agent getter and the captured reference. Bind the built-in `prompt`
and `pick` actions in `pigeon.keymaps`, then open Pigeon from a source file
window:

```lua
require("aviary").pigeon.show()
-- In the Terminal, press the prompt keymap to send a template about that reference,
-- or the pick keymap to switch Agents.
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
      close = { "q" }, hawk = { "<CR>" }, refresh = { "r" },
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
