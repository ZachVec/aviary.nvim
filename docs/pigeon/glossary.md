# Pigeon glossary

| Term | Meaning |
| --- | --- |
| Tool | A named Agent command and optional reference formatter. |
| Agent | One running tool instance, backed by a persistent tmux session with exactly one agent window. It carries its tool key and launch cwd, survives editor clients, and is the selectable delivery destination. _Avoid_: Target, Receiver. |
| Choice | An existing Agent or an intent to create one; creation waits for selection. |
| Terminal | The Neovim buffer, optional floating window, attach job and client displaying one Agent; each editor owns at most one. It stores the client, not an Agent. |
| Client | The tmux client attached from one Terminal, identified by its PTY/`client_name`. Multiple clients may attach to the same Agent. |
| Current Agent | The Agent displayed by a Terminal's client, resolved from tmux when an action calls its `current()` getter. |
| Reference | A plain snapshot of a filename and optional inclusive rows, captured when the Terminal is shown and rendered later for the current Agent. It is not a buffer handle. |
| Action | A configured handler installed as Terminal-buffer keymaps; it receives a lazy current-Agent getter and the captured reference. Built-ins are `buffers`, `close`, `pick` and `prompt`. |
| Buffers action | The built-in action that selects one listed, named buffer with an empty `buftype` and sends its path as a whole-file reference. |
| Resolver | A configured prompt-token handler receiving the Agent and reference and returning text. Built-ins are `file` and `line`. |

The tmux session and window belong to their Agent. "Agent session" may be used
when the tmux resource itself is the subject; it is not a separate entity.
Message, Weaver, Selection, Anchor, View and Attachment are retired terms. A
"files action" is user-written picker integration; Pigeon core ships none. The
built-in buffers action uses `vim.ui.select`.

Interfaces live in the [config entry](../../lua/aviary/pigeon/config.lua),
[backend entry](../../lua/aviary/pigeon/backends/init.lua) and
[Pigeon entry](../../lua/aviary/pigeon/init.lua).
See [architecture](./architecture.md) for collaboration and resource lifetimes.
