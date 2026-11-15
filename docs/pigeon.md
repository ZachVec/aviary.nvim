# pigeon

Create, select and show receivers, and deliver captured Messages to one current
target. See [installation](../README.md#installation) and
[requirements](../README.md#requirements). Pigeon accepts content from
[weaver](./weaver.md) or your own Message construction.

## Usage

<!-- vimdoc: pigeon.nvim-api pigeon.pick() pigeon.show() pigeon.send() pigeon.status() -->

```lua
local aviary = require("aviary")
local pigeon = aviary.pigeon
local Message = require("aviary.shared.message")
pigeon.pick()   -- choose and display a new tool or existing default-backend target
pigeon.show()   -- display the current receiver
pigeon.send(Message.reference("/project/src/a.lua", 12, 15))
pigeon.status()

aviary.weaver.files()  -- capture file references and send them
aviary.weaver.prompt() -- choose {line} for the cursor line or Visual range
```

`pick`, `show`, and `status` take no arguments. `send(message)`
accepts a Message. These actions do not return values; failures notify and
picker cancellation is quiet. Discovery and delivery complete
synchronously; when a picker opens, the action resumes after confirmation.

## Exporting and selection

These settings also apply to Messages sent by Weaver actions.
`backend.default` controls discovery, selection and creation. It defaults
to `clipboard`; select `tmux` to create tool receivers:

```lua
require("aviary").setup({
  pigeon = {
    backend = {
      default = "tmux", -- clipboard | tmux
      tmux = { width = "90%", height = "90%", close = "C-." },
    },
  },
})
```

There is one current target across all callers. `pick()` discovers existing
targets and tool creation choices from the default backend. A sole candidate is
selected directly; multiple candidates are listed in `vim.ui.select`.
Each entry starts with a toggle icon: `` for a tool to create and `` for an
existing target. Choose a ` <tool>` entry to create another instance on that
backend, or an existing target to reuse it. The current target is marked with
`[current]` and placed first; tool entries follow the targets in name order.
Existing tmux entries show ` {tool} {agent cwd} [{instance}]`; the agent's
captured launch directory uses `~` only for its home prefix, and instance is
hexadecimal without leading zeroes. New tool entries show only ` {tool}`.
Clipboard is named `clipboard` and is selected directly without a picker.
`pick()` sets current and immediately displays the selected or newly created target.

When current is empty, `show` and `send` use the same selection rules and continue
only after successful selection or creation. An action exception reports its
error, clears current and ends that request, including creation, evaluation, show
and send failures. The next explicit action selects again. Use `pick()`
to rediscover or switch targets explicitly. `show` displays once; `send` delivers once without automatically
retrying or reopening the picker. Cancelling selection sends nothing.
A pending picker keeps its original backend. Tmux discovery is scoped to Neovim's
host server; receivers on other servers are outside that inventory.

Changing the default does not replace a valid current. Successful selection or
creation replaces it; cancellation and discovery failure preserve the previous
selection, while failed resolution or creation clears it. Pigeon evaluates the Message through the selected
Target before delivery; failure in either evaluation or delivery clears current
and is reported once by Pigeon. Other
backends' targets are not added to the default backend's list.

`send` delivers the evaluated Message to the selected target without changing focus.
Success acknowledges the delivery request, not processing or external receipt.

## Tools

`pigeon.format` is the default reference formatter. A tool's own `format` takes
priority; tools without an override and the clipboard use the default. Codex
uses the default, shipped as `file :L12-15`; Claude has its own `@file#L12-15`
formatter. Each named tool owns its argv independently of its backend.

Built-ins are `codex` and `claude`; partial overrides preserve their other fields.
New tools require `command`; `format` is optional. For example:

```lua
require("aviary").setup({
  pigeon = {
    format = function(path, first, last)
      if not first then return path end
      return path .. ":" .. first .. (last and last ~= first and "-" .. last or "")
    end,
    tools = {
      codex = { command = { "codex", "--model", "my-model" } },
      custom = {
        command = { "my-cli" },
        format = function(path, start_row, end_row)
          if not start_row then return path end
          return path .. ":" .. start_row .. (end_row and "-" .. end_row or "")
        end,
      },
    },
  },
})
```

`command` is a nonempty argv list, executed without interpreting its strings as
shell commands. Selecting a tool in the picker creates it directly, using its
configuration and cwd when creation begins. Only a fully constructed target
replaces current. When `pick` or `show` requested the choice, it then displays
that target; a failed display clears the selection and leaves the agent session
available for selection on a later action.

`format(path, start_row?, end_row?)` receives a path spelled by the
[backend](./pigeon.md#backends). Rows are 1-based and inclusive;
nil start means the whole file, and end is optional. Codex uses `file :L12-15`;
Claude uses `@file#L12-15`, quoting unusual paths. The function must return a
nonempty string. A nil/empty/non-string result or exception fails the entire
Message before any text is delivered.

Each send resolves the tool's formatter by name in the sending Neovim's current local
config, falling back to `pigeon.format` when the override is absent. The default
is also resolved at each clipboard send. Updating a formatter affects the next send; it does not change a running
program's argv or creation cwd.

## Backends

Clipboard requires a working provider. `send` writes the `+` register, using
absolute references formatted through the current `pigeon.format`. Empty text
clears the register. `show` reads and notifies its current contents, including an
explicit empty-content notice.
Clipboard does not host tools, so only its target is offered and selected directly.

Tmux requires tmux 3.8+ and Neovim running inside an existing tmux server.
The host must allow detached sessions to survive initialization, normally with
global `destroy-unattached=off`; Pigeon trusts this prerequisite without checking it.
`TMUX` and `TMUX_PANE` supply the trusted host context. Receivers and
floating views live on that same server. Pigeon uses its existing configuration
and does not start a private server or load tmux configuration.
Each receiver consists of one detached session, one window and one agent pane.
Receivers are visible in your normal `tmux list-sessions`. Discovery includes only
sessions with a nonempty `@pigeon_tool` attribute. Unmarked sessions are
ignored even when their window names match a configured tool. Queries with no
matching receivers succeed with an empty result; command failures are reported
normally.

References are relative to the tool's creation cwd when inside it, otherwise absolute.
Sending fills the tool's draft without pressing Enter or opening its view; empty
text sends nothing. A sending failure is reported and clears current while leaving
the existing display alone. Message evaluation happens before delivery. A later
user action can select another target and evaluate its own Message again.
Use `show` from a tmux window with an attached client. It opens a native,
nonmodal floating pane that attaches to the receiver. Neovim does not
render the terminal. The tiled panes keep their geometry and zoom, and no extra
windows are added to the source session.

A receiver window starts with the tool's name, but user or program renames do not
affect discovery. Receivers set `status=off`, `prefix=None`, `prefix2=None`,
`destroy-unattached=off`, and `detach-on-destroy=on`. The agent window explicitly
sets `remain-on-exit=off`; `allow-rename` follows user policy. Process exit removes
the agent pane and its session naturally. The launch directory remains the
reference base even if the process changes its current directory.

Other settings, including extended-key behavior, inherit your server configuration.
Server options remain shared; Pigeon does not snapshot or synchronize them or
override extended keys. User hooks and tmux plugins can still affect receivers.

Another Neovim on the same tmux server can rediscover a receiver and use its own
same-named formatter. Discovery skips tools absent from local configuration,
leaving their resources intact. Restoring the tool definition makes those targets
discoverable again.
Sending to a selected target whose local tool definition was removed fails explicitly.
Current may refer to an exited receiver; there is no background liveness watcher.
Use `pick()` to select another target.

Each source pane reuses its existing floating view or opens one when absent.
Other floats, including displays owned by another Neovim in the same window, are
left alone.

Reusing a view reapplies dimensions and preserves the agent process and draft.
Switching targets can reuse the same float. A failed show may close its view,
including a reused view. The receiver keeps running, and the next show can create
another display. Different Neovims can show different receivers or the same
receiver concurrently. Views of one receiver share its input, draft and terminal
size under tmux's window-size policy.
A view belongs to its source tmux window: switching windows leaves it attached in
that window, and switching back reveals it again.

Width and height use tmux-native strings, including the floating pane's border:
`"90%"` is a percentage of the source window, `"100%"` fills that dimension,
and `"80"` is an absolute cell count. Values contain a positive integer,
optionally followed by `%`. Tmux resolves dimensions on each show; Pigeon does
not query window geometry or calculate sizes.
`close` is a tmux key, default `C-.`. It detaches that
view's client and removes the floating pane; the tool and draft remain running.
Close-key changes apply on the next show. Every show binds close in the dedicated
shared `aviary-pigeon` key table and selects that table for the receiver.
The most recent focus configuration applies to all receivers using that table.
Run `:checkhealth aviary` inside tmux to check the close key against the current
outer key table and prefixes. Business operations do not check conflicts.
The key must reach the nested attach client; an outer binding or prefix can consume
it first. Health checks are read-only and never start a server or install bindings.
Before a receiver close binding exists, health cannot rule out key-alias conflicts
and asks you to show a receiver before checking aliases.
Pigeon leaves your root/global bindings and tmux configuration unchanged.

Your source session's statusline options and automatic renaming follow your
configuration. Native status fields can therefore reflect the active floating
pane's command or title, including a changed source window name.

Closing Neovim leaves an existing view available; press its close key manually.
No editor-exit cleanup is registered. Receivers are independent of editors,
views, source windows and source sessions, so closing any of these leaves receivers
running. Shutting down the host server stops them all. To stop one receiver, show
it and exit normally inside the program; its pane/session disappear and attached
clients exit. The shared receiver key table has no per-target cleanup.
There is no `stop` interface. Zellij is not implemented.

## Messages

The [shared Message module](../lua/aviary/shared/message.lua), loaded through
`require("aviary.shared.message")`, provides constructors: `text(string)`,
`reference(absolute_path, start_row?, end_row?)`, and `join(delimiter, children)`.
They construct captured Text, Reference and Join nodes. A filename may be empty
for an unnamed source; that Reference fails evaluation. Keep trees unchanged
from the call to `send` until evaluation completes, including time spent waiting
for a picker. Pigeon calls the selected Target's eval method, which supplies the
formatting context and evaluates the whole tree. Only after success does Pigeon
call that Target's send method with the resulting string. Each successful Reference preserves the formatter's
result verbatim. Shared Message has no built-in reference syntax.

## Health and migration

Run `:checkhealth aviary.pigeon` for configuration, backend dependencies and tool
executables. Tmux diagnostics check context, version and outer close-key conflicts
through read-only queries. Health does not discover receivers or acquire resources.
Business actions trust the host context and let command errors propagate without
health or existence preflights. Setup only merges and validates configuration;
it acquires no resources and does not require tool executables to be installed.
Unknown options, fields under `backend`/`backend.tmux`, and fields inside each
tool definition are rejected; tool names remain user-defined. `pigeon.setup(opts)`
returns `false, reason` on invalid options and keeps the previous configuration
and current target. See [setup scope](../README.md#installation) for which features
reset through root and direct feature setup.

Remove the old tmux socket setting. Existing private-server receivers are not
migrated or discovered; there is no compatibility layer or cross-server receiver
pool. Create new receivers from Neovim running inside the server you want to use.

The previous content feature is now `aviary.weaver`. Replace content calls and
the root `prompt/files/buffers/text` actions with the no-argument
[Weaver actions](./weaver.md#usage), which send directly through Pigeon.
Move root `picker.implementation` to `weaver.picker`. Replace root `exporter`
options with `pigeon.backend`, `pigeon.format`, and tool-specific
`pigeon.tools.<name>.format` overrides.
Replace internal `shared.exporter.run/select/status` calls with public
`aviary.pigeon.send/pick/status`. References now receive raw rows rather than
preformatted location strings. The old exporter/picker module paths are removed.

Replace `pigeon.select()` with `pigeon.pick()`. Tool creation is also selected
through `pick()`; the public `create()` action is removed. To create and display
a tool, choose it through `pick()`, or call `show()` without a current target.
Replace `pigeon.message` with `require("aviary.shared.message")` to construct Messages.
