# pigeon

Create Agents, show them in a Neovim Terminal, and run actions that send
references or prompts to the current Agent. See
[installation](../README.md#installation) and
[requirements](../README.md#requirements).

## Usage

<!-- vimdoc: pigeon.nvim-api pigeon.show() -->

```lua
local aviary = require("aviary")
local pigeon = aviary.pigeon
pigeon.show() -- show/create this Neovim's Terminal; choose an Agent when none is attached
```

`show()` captures the current editor reference before changing focus. Actions
run from the Terminal and receive a lazy current-Agent getter and that
reference. There is no public send function: compose and deliver content inside
an [action](#actions). Actions return nothing. Failures notify once; picker
cancellation is quiet and preserves the current Agent. Requests are never
automatically replayed. Empty text does nothing.

The built-in close action, bound to `<C-.>` by default, closes only the Neovim
window. `show()` reopens it in Terminal mode. The attach client and buffer
remain alive while hidden.

## Actions

`keymaps` maps action names to lists of Neovim keys. Each list replaces its
defaults, and `{}` disables that action's keys. `actions` maps action names to
handlers and merges over built-ins. Handlers receive a getter for the current
Agent and the captured reference:

```lua
---@param current fun(): aviary.pigeon.Agent
---@param reference aviary.pigeon.Reference
```

`current()` resolves the Agent displayed by the Terminal's tmux client and
raises when that client is not attached to a Pigeon Agent. It is not memoized:
call it once and cache the result when a handler needs the Agent more than once.
`close` and actions that do not use the Agent never call it, so they perform no
tmux lookup.

Pigeon resolves keymaps and actions when it creates the Terminal. The keymaps
are buffer-local and active in Terminal mode. Later setup changes apply to new
Terminals. Every mapped action needs a handler. Built-ins are available by name.

Built-ins are `buffers`, `close`, `pick` and `prompt`. `buffers` selects one
file-backed listed buffer and sends its path. `close` closes the current window.
`pick` switches the Terminal's Agent and marks the current Agent in its selector.
`prompt` selects a named template and sends it. The selectors resume Terminal
input on confirmation or cancellation. `buffers`, `pick` and `prompt` use only
the keys you configure.

```lua
require("aviary").setup({
  pigeon = {
    keymaps = {
      buffers = { "<C-b>" },
      close = { "<C-.>" },
      pick = { "<F5>" },
      prompt = { "<C-p>" },
    },
  },
})
```

### Sending content

`agent:send(text)` pastes raw text without focusing or submitting. To render a
file reference, use `agent:eval(reference)` first. A reference is a plain table:

```lua
---@class aviary.pigeon.Reference
---@field path string
---@field start_row? integer
---@field end_row? integer
```

`start_row` and `end_row` are 1-based inclusive rows; omit both for a whole-file
reference and omit `end_row` for a single row. `Agent:eval` resolves the path
relative to the Agent's launch cwd and calls the Agent's current formatter. It
raises when the path is empty or the formatter returns no text. Render every
reference before sending so a failure cannot deliver partial content.

```lua
local texts = {}
for _, path in ipairs(paths) do
  texts[#texts + 1] = agent:eval({ path = path })
end
agent:send(table.concat(texts, "\n"))
```

### Buffers action

The built-in `buffers` action lists buffers that are listed, named, and have an
empty `buftype`. It opens `vim.ui.select` and sends a whole-file reference for
the selected buffer's path. Confirming or cancelling resumes Terminal input. It
warns when no such buffer exists. The action selects one buffer at a time;
define a custom action if you need multi-selection. It reads no buffer contents,
so unsaved changes are not included.

```lua
require("aviary").setup({
  pigeon = {
    keymaps = { buffers = { "<C-b>" } },
  },
})
```

The selector is the editor's configured `vim.ui.select` implementation; Pigeon
does not choose or depend on a picker.

### Files action

Pigeon ships no built-in `files` action. Define it with whichever picker you use.
The picker owns discovery, previews, selection rules and its own cleanup; deliver
after its UI has closed.

Snacks example:

```lua
local function send_paths(agent, paths)
  local texts = {}
  for _, path in ipairs(paths) do
    texts[#texts + 1] = agent:eval({ path = path })
  end
  agent:send(table.concat(texts, "\n"))
end

require("aviary").setup({
  pigeon = {
    keymaps = { files = { "<C-f>" } },
    actions = {
      files = function(current)
        local agent = current()
        local picker = require("snacks").picker
        picker.pick("files", {
          confirm = function(selected)
            local paths = {}
            for _, item in ipairs(selected:selected({ fallback = true })) do
              local path = picker.util.path(item)
              if path then
                paths[#paths + 1] = path
              end
            end
            selected:close()
            vim.schedule(function()
              send_paths(agent, paths)
            end)
          end,
        })
      end,
    },
  },
})
```

Other pickers use the same contract: select absolute paths in confirmation
order, close their UI, then call `agent:eval` and `agent:send`. The action owns
asynchronous error handling; wrap delivery yourself if the picker can fail after
it closes.

## References

`show()` captures a reference before focusing the Terminal. In Visual mode the
reference contains the inclusive whole-line range and Pigeon exits Visual;
otherwise it contains the cursor row with `end_row` omitted. The path is
snapshotted at capture time, so later renames or edits do not change an already
captured reference; show the Terminal again to refresh it. Capturing does not
open or validate the file.

Invocations from the Terminal itself do not replace the reference. Actions run
from the Terminal therefore always see the last reference captured from an
editor window; the `pick` action likewise preserves it. The reference is plain
data, not a buffer handle: closing the source window does not invalidate it.

Action handlers may construct whole-file references and references to other
paths. `Agent:eval` only renders them; it does not read or modify the source.

## Prompts

The built-in `prompt` action resolves the current Agent once, then uses the
captured reference and a named template. Bind it in the Terminal:

```lua
require("aviary").setup({
  pigeon = {
    keymaps = { prompt = { "<C-p>" } },
  },
})
```

Capture a reference first. For a Visual range, call `show()` from Visual mode;
for a normal-mode mapping, the cursor line is captured. See
[references](#references) for capture timing.

Templates and resolvers merge with Pigeon's defaults:

```lua
require("aviary").setup({
  pigeon = {
    prompts = {
      ["{file}"] = "{file} ",
      ["{line}"] = "{line} ",
      review = "Review {line} for bugs.",
    },
    resolvers = {
      rows = function(_, reference)
        local last = reference.end_row or reference.start_row or 0
        return tostring(last - (reference.start_row or 0) + 1)
      end,
    },
  },
})
```

The built-in resolvers are `file` (a whole-file reference) and `line` (the
captured file and row or range). A resolver receives the Agent and the
reference, and returns a string:

```lua
---@alias aviary.pigeon.Resolver fun(agent: aviary.pigeon.Agent, reference: aviary.pigeon.Reference): string
```

Resolvers can render references with `agent:eval` and may return any text,
including composites. Names in templates use letters, digits and
underscores. Only the selected template is expanded, once per occurrence, in
token order. Tokens without a resolver are sent verbatim; literal spacing,
punctuation, percent signs and newlines are preserved. The template and
resolvers are captured before the selector opens; setup changes apply to the
next invocation. The selector lists the configured prompt names. Cancellation
calls no resolvers and sends nothing. Resolver and rendering errors notify once
without delivering partial content.

Prompt capture exits Visual mode before changing focus. Use a Lua callback or
`<Cmd>` Visual mapping to retain the active selection until `show()` or the
action runs.

## Agents and display

There is one Terminal per Neovim, and it has one current Agent. `show()` lists
existing Agents and creation choices in `vim.ui.select` when no Terminal exists;
the built-in `pick` action lists them when a Terminal is attached. A single
candidate is still passed to the configured picker. Entries begin with
` <tool>` to create an instance or ` <tool> <launch cwd> [<tag>]` to
reuse an Agent. The tag is the Agent's tmux pane id. Existing Agents are sorted
by launch cwd, followed by creation choices. The pick action puts the current
Agent first with `[current]`, followed by other Agents with the same launch cwd.
Discovery includes only Pigeon Agents on Neovim's host tmux server whose tool
names exist in local configuration. Renaming a tmux window does not change an
Agent's identity or formatter.

Each Agent has its own persistent tmux session with one agent window. This
Neovim's client attaches directly to that session; no temporary View session is
created. Switching Agents reuses the Terminal buffer, job and client: the
existing tmux client moves to the new Agent session. Different editors choose
independently, and multiple editors attached to the same Agent share its input
and output. Terminal size follows your tmux `window-size` policy; Pigeon does not
override it.

Closing the window keeps the buffer, job and client attached. Exiting Neovim
detaches that editor's client and preserves the Agent. Exiting an Agent removes
its only window and session, ending its attached clients; their `TermClose`
events close the corresponding Neovim Terminals. Closing the tmux server stops
all Agents.

Configure the float:

```lua
require("aviary").setup({
  pigeon = {
    view = { width = 0.9, height = 0.9, border = "rounded" },
  },
})
```

Width and height are fractions in `(0, 1]` or integer cell counts greater than
one. Sizes refer to the float's content and are clamped to the available editor
area. Border accepts `none`, `single`, `double`, `rounded`, `solid` or `shadow`.
The float fixes its Terminal buffer with `'winfixbuf'`; switching it to another
buffer is unsupported. Width, height and border apply when a window is opened or
reopened. A visible window keeps its size when the editor is resized; hiding and
showing it recalculates the geometry.

Pigeon uses tmux's default socket and your existing server configuration, and
starts no private server. Neovim must run inside tmux with `TMUX` set. Each Agent
session sets `destroy-unattached=off`, `detach-on-destroy=on`, `status=off`,
`prefix=None` and `prefix2=None`; its window sets `remain-on-exit=off` and
`pane-border-status=off`. These options keep the Agent alive without clients,
ensure an exiting Agent ends its clients instead of moving them elsewhere, and
remove the pane border. No global tmux key tables, hooks or key bindings are
installed.

Keyboard input passes through Neovim's terminal handling before reaching the
nested tmux client. Pigeon installs no modified-Enter mappings by default; these
keys follow Neovim and your own configuration. A custom action runs in the
Terminal buffer and can forward the CSI-u sequence through that buffer's
terminal job when your outer terminal reports Shift+Enter distinctly:

```lua
require("aviary").setup({
  pigeon = {
    keymaps = { shift_enter = { "<S-CR>" } },
    actions = {
      shift_enter = function()
        vim.api.nvim_chan_send(vim.b.terminal_job_id, "\27[13;2u")
      end,
    },
  },
})
```

The Terminal buffer filetype is `aviary-pigeon` for user customization. Outer
tmux bindings may consume keys before Neovim sees them.

## Tools and formatting

Built-ins are `codex` and `claude`. Partial overrides preserve their other
fields. Custom tools require a nonempty `command` list with the program name
first. Supply arguments without embedded NUL bytes. Commands execute directly,
without shell interpretation. The editor's cwd is captured when creation begins.

```lua
require("aviary").setup({
  pigeon = {
    tools = {
      codex = { command = { "codex", "--model", "my-model" } },
      custom = {
        command = { "my-cli" },
        format = function(path, first, last)
          return path .. (first and ":" .. first or "")
            .. (first and last and last ~= first and "-" .. last or "")
        end,
      },
    },
  },
})
```

Each reference is rendered using the Terminal's current Agent. That Agent
supplies its launch cwd and the current local same-named tool formatter. Paths
inside the launch cwd are relative; others stay absolute. Set `format` under the
tool to give it a custom formatter. Codex and custom tools default to
`file :L12-15`. Claude defaults to `@file#L12-15`, quoting unusual paths.

Pigeon changes the Agent displayed by this editor's tmux client only through
`show()` creation or the `pick` action. Actions resolve the current Agent from
that client, so an external move to another Pigeon Agent is followed on the next
action; moving the client to a non-Pigeon session makes actions that resolve the
Agent fail with a warning. The Agent session disables its prefix and status line
so normal key input cannot move the client by accident.

`format(path, start_row?, end_row?)` receives raw 1-based inclusive rows; nil
start means the whole file. It must return a nonempty string. Updating local
formatters affects the next render without changing a running Agent's argv or
launch cwd. Removing its local tool definition makes rendering fail and hides it
from discovery, leaving the Agent running.

Delivery uses tmux bracketed paste when the Agent supports it, preserving raw
newlines. Success acknowledges the paste request, not processing by the Agent.
A failed evaluation or delivery reports once, preserves the current Agent and
ends the request. There is no fallback to an earlier Agent.

## Health and migration

Run `:checkhealth aviary.pigeon` for tmux version/context and tool executables.
Health is read-only. Setup merges defaults and checks configuration structure
before any runtime resources are acquired. Callers supply valid option values
for use at runtime. `pigeon.setup(opts)` returns `false, reason` and preserves
running configuration on validation failure. See [setup scope](../README.md#installation).

Move a former top-level `pigeon.format` to `pigeon.tools.<name>.format` for
each tool that used it.

Weaver, its text action, the shared Message tree and the built-in picker
configuration are removed. Use Pigeon actions instead: `prompt`, `pick` and
`buffers` are built in, and files actions are user actions for your picker.
Action handlers receive a `current` getter; resolve the Agent once, then use
`agent:eval` and `agent:send`. Raw text can be pasted with your editor or agent,
or sent from a custom action. There is no public `pigeon.send`, `pigeon.pick` or
`pigeon.status`; compose content in actions and switch Agents with the `pick`
action. References are plain `{ path, start_row?, end_row? }` tables rendered
with `agent:eval`. Clipboard support and the old nested `pigeon.backend`
configuration remain removed; only the `tmux` backend is available. Sessions
created by the previous receiver/View model are not migrated into the new
discovery format; create fresh Agents through `show()` or the `pick` action.
