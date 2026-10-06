# aviary.nvim

One Neovim plugin, several birds.

aviary is one plugin holding a set of subsystems. Today:

| Subsystem | What it does |
| --- | --- |
| `aviary.hawk` | Walks a git change set — the index, the working tree, or a revision range — as a flat list of files and hunks you tick off as you read |
| `aviary.pigeon` | Sends a prompt, a reference, a comment, or the selection into the other panes of the multiplexer window this Neovim sits in |

The subsystems are called from Lua —
`require("aviary").hawk.open({})`, `require("aviary").pigeon.files()` — and
there are no user commands in the end state. During the migration the old
`:Hawk` and `:Pigeon` commands still work.

> **Status: being assembled.** aviary is the merge of hawk.nvim (review) and
> pigeon.nvim (send). This repository currently holds the tooling and the
> composition root; the subsystems land as `aviary.hawk` and `aviary.pigeon`
> in the following commits. See [docs/migration.md](docs/migration.md) for the
> plan and its gates.

## Install

aviary is not published yet. During the migration, load the checkout directly:

```lua
{
  dir = "~/playground/aviary.nvim",
}
```

## Requirements

- Neovim ≥ 0.11

## License

MIT
