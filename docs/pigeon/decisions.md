# Pigeon decisions

Caller contracts belong to the [Pigeon entry](../../lua/aviary/pigeon/init.lua),
[config entry](../../lua/aviary/pigeon/config.lua) and
[backend entry](../../lua/aviary/pigeon/backends/init.lua).
See [architecture](./architecture.md) for collaboration and resource lifetimes.

## Actions own send workflows

Pigeon exposes no public send function. Action handlers receive the current
Agent and the captured reference, and call `agent:send`/`agent:eval` themselves.
Files/buffers actions are user configuration rather than built-ins so Pigeon
carries no picker interface or optional picker dependency; the cost is that users
write the picker integration and own its asynchronous cleanup.

## Actions receive the Agent, not the Terminal

Rendering and delivery are Agent operations; the Terminal is the editor
buffer/window frame that owns the keymaps. Passing the Agent keeps buffer, job
and client details out of every handler, while a Terminal-buffer keymap can still
read buffer-local terminal state such as `b:terminal_job_id` for input
forwarding. The cost is that actions cannot reach the Terminal object directly
and must use the keymap's buffer for terminal-level customization.

## Reference capture belongs to show and pick

`show()` and `pick()` snapshot the current file, cursor row or Visual whole-line
range before changing focus. The reference is plain data stored with a
snapshotted path, so no buffer handle has to be cleaned up or validated; the
cost is that a reference can become stale and must be refreshed by showing the
Terminal again.

## Plain references render through the Agent

A reference is a fixed-key table (`path`, optional `start_row`, optional
`end_row`); `Agent:eval` resolves it against the Agent's cwd and formatter.
There is no Message tree: actions join strings directly, and prompt resolvers
receive the Agent and reference and return strings. This keeps agent-specific
rendering in one place and lets resolvers compose freely, while users who need a
different join or layout override the action or resolver.

## Built-in actions and resolvers live in config

`close` and `prompt` handlers, default prompts and built-in `file`/`line`
resolvers live in the config defaults, so user overrides merge naturally and
keymap validation recognizes built-in action names without a separate registry.
The trade-off is that the config module contains the prompt workflow rather than
only data; the alternative was an init-side built-in table duplicating the names.

## Host server, one Agent per session

Agents use Neovim's host tmux server to inherit user configuration without
option snapshots or synchronization. Each Agent owns one persistent session and
one window so Agent exit naturally ends its clients and closes their Terminals;
putting several Agents in one shared window collection would keep those clients
alive when one Agent exits. Agent sessions set `destroy-unattached=off`,
`detach-on-destroy=on`, `status=off`, `prefix=None` and `prefix2=None`; windows
set `remain-on-exit=off` and `pane-border-status=off`.

## Default tmux socket

Pigeon starts attach clients with `TMUX` cleared and no `-S` or `-L`, so they use
tmux's default socket. Operations already inherit Neovim's host server; relying
on the default socket avoids parsing `TMUX`, while custom-socket servers are
unsupported.

## One Terminal, direct client switching

Each Neovim owns one Terminal and one client. Changing Agents moves that client
with `switch-client` to the new Agent session, reusing the Neovim buffer, attach
job and PTY. A temporary per-editor View session is unnecessary because every
Agent session has one window; the temporary session would add creation,
discovery, grouping and cleanup work and would still need the client identity for
cross-session switching.

The client's tmux identity is its `client_name`, which is the PTY path returned
by `nvim_get_chan_info(job).pty`; tmux exposes no separate numeric client id.
The PTY is unique per attach job, while an Agent session may have several clients
from different editors. Attach and retarget use `-t =<session>` exact matching so
a stale Agent fails instead of resolving to a prefix-named session.

## Terminal Agent is the delivery source

Delivery uses the Terminal's stored Agent; it does not query tmux selection
first. One Agent session has one window, and Pigeon changes the client only after
a successful retarget, so this field is authoritative in supported flows.
Manually moving the client outside Pigeon is unsupported. Disabling the Agent
session's prefix and status line keeps normal terminal input from moving the
client by accident. A cached Agent avoids a query before every action and makes
hidden delivery independent of focus.

## Terminal float fixes its buffer

The Terminal float sets `winfixbuf` so it always displays the Terminal buffer.
This enforces Pigeon's one-window mapping and lets `TermClose` close the window
by deleting the buffer rather than calling a window API; switching the float to
another buffer is unsupported. A forced command can still bypass the option.

## TermClose lifecycle, synchronous cleanup

A buffer-local `TermClose` listener owns normal cleanup. Neovim reports
`status == -1` when the terminal is closing because its buffer is being deleted
by `close_buffer()`; the callback then clears Pigeon state and leaves the window
and buffer to the external deletion. For normal exits and `jobstop`, the buffer
still exists, so the callback deletes it and releases the listener group
synchronously. The fixed float closes with its buffer, so cleanup needs no
separate window close and must not rely on `WinClosed`.

`TermClose` is registered after all fallible acquisition, and the callback
clears shared state before using captured resources. A newer Terminal therefore
cannot be cleared by an older callback; an instance-ownership check would only
hide a broken invariant. Deferred cleanup with `vim.schedule` would reintroduce
that race and a queue window, so cleanup stays synchronous.

## Terminal creation does not require a window

`Terminal.create` starts the attach job in its hidden buffer with
`nvim_buf_call`; the float is acquired only when shown. This lets creation
succeed and remain usable for actions or a later show if window acquisition
fails, and removes the ordering requirement between the job and the window. The
cost is that the PTY initially has the temporary autocmd window's size, then
resizes when the float opens; a tmux client can observe that initial size before
the final one. Opening the window first would avoid the transient size but couple
Terminal creation to display.

## Geometry is applied only when a window is created

Hiding the Terminal closes only the float; showing the hidden Terminal creates a
new float with the current geometry and resizes the PTY. Focusing an already
visible float does not change its geometry, and Pigeon does not listen to
`VimResized`. This keeps Pigeon from continuously driving layout and tmux size
while the editor is resized; the cost is that a visible Terminal keeps its older
size until hidden and reopened.

## Leave modified Enter to user configuration

Neovim's terminal input may encode modified Enter differently from the outer
terminal, even with tmux extended keys enabled. Pigeon installs no built-in
forwarding mappings, but a custom Terminal-buffer action can read
`b:terminal_job_id` and send the sequence its environment requires.
