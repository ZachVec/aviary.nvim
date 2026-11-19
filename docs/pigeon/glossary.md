# Pigeon glossary

| Term | Meaning |
| --- | --- |
| Tool | A named Agent command and optional reference formatter. |
| Agent | One running tool instance, backed by a persistent tmux session with exactly one agent window. It carries its tool key and launch cwd, survives editor clients, and is the selectable delivery destination. _Avoid_: Target, Receiver. |
| Choice | An existing Agent or an intent to create one; creation waits for selection. |
| Terminal | The Neovim buffer, optional floating window, attach job and client displaying one Agent; each editor owns at most one. |
| Client | The tmux client attached from one Terminal, identified by its PTY/`client_name`. Multiple clients may attach to the same Agent. |

The tmux session and window belong to their Agent. "Agent session" may be used
when the tmux resource itself is the subject; it is not a separate entity.
Anchor, View and Attachment are retired terms from the previous display model.

Interfaces live in the [backend entry](../../lua/aviary/pigeon/backends/init.lua)
and [Pigeon entry](../../lua/aviary/pigeon/init.lua).
See [architecture](./architecture.md) for collaboration and resource lifetimes.
Message and Reference are defined in the
[shared Message glossary](../shared/message/glossary.md).
