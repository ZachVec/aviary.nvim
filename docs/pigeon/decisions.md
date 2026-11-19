# Pigeon decisions

Caller contracts belong to the [Pigeon entry](../../lua/aviary/pigeon/init.lua)
and [backend entry](../../lua/aviary/pigeon/backends/init.lua).
See [architecture](./architecture.md) for collaboration and resource lifetimes.

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

A send uses the Terminal's stored Agent; it does not query tmux selection first.
One Agent session has one window, and Pigeon changes the client only after a
successful retarget, so this field is authoritative in supported flows. Manually
moving the client outside Pigeon is unsupported. Disabling the Agent session's
prefix and status line keeps normal terminal input from moving the client by
accident. A cached Agent avoids a query before every send and makes hidden sends
independent of focus.

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
succeed and remain usable for sends or a later show if window acquisition fails,
and removes the ordering requirement between the job and the window. The cost is
that the PTY initially has the temporary autocmd window's size, then resizes
when the float opens; a tmux client can observe that initial size before the
final one. Opening the window first would avoid the transient size but couple
Terminal creation to display.

## Geometry is applied only when a window is created

Hiding the Terminal closes only the float; showing the hidden Terminal creates a
new float with the current geometry and resizes the PTY. Focusing an already
visible float does not change its geometry, and Pigeon does not listen to
`VimResized`. This keeps Pigeon from continuously driving layout and tmux size
while the editor is resized; the cost is that a visible Terminal keeps its older
size until hidden and reopened.

## Leave modified Enter to Neovim and user configuration

Neovim's terminal input may encode modified Enter differently from the outer
terminal, even with tmux extended keys enabled. Follow normal terminal handling
without built-in forwarding corrections; users can configure their own Terminal
mappings without Pigeon imposing an agent-specific key policy.
