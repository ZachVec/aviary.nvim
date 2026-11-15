# Pigeon glossary

| Term | Meaning |
| --- | --- |
| Tool | A named receiving program's launch command and optional reference formatter. |
| Choice | A selectable existing destination or creation intent. Creation is deferred until resolution to a Target. |
| Target | A resolved destination for Message evaluation and delivery. Each Neovim keeps one current Target reference, which may outlive its receiver. |
| Receiver | A running tool instance hosted in an independent tmux session. |
| View | A floating tmux pane attached to a Receiver; closing it leaves the Receiver running. |

Interfaces live in the [backend entry](../../lua/aviary/pigeon/backends/init.lua).
See the [architecture](./architecture.md) for discovery, selection and resource
lifetimes.

Message and Reference are defined in the
[shared Message glossary](../shared/message/glossary.md).
