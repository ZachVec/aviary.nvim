# AGENTS.md

aviary is one Neovim plugin that hosts a set of subsystems. Today:

- **hawk** — walk a git change set as a flat, tickable list of files and hunks.
- **pigeon** — send text from Neovim into the other panes of the multiplexer
  window this Neovim sits in.

The set is not closed. A subsystem is a directory under `lua/aviary/`, and the
root module knows no names: `require("aviary").<name>` is a lazy `require` of
`aviary.<name>`, so a third one adds a directory, not a case in the root.

Each subsystem keeps its own design record, glossary, and gotchas, and its own
`AGENTS.md` beside its code. This file is the repository-wide contract: the
layout, the conventions that hold everywhere, and the migration that is
bringing the two in. The migration plan and its gates live in
[docs/migration.md](docs/migration.md).

## Repository layout

```
lua/aviary/
  init.lua          composition root: lazy subsystem access + the shared config table
  <name>/           one subsystem: its own AGENTS.md, config, docs, and tests
  hawk/             hawk: source, model, view
  pigeon/           pigeon: transport, picker, formats
doc/                vim help: :h hawk.nvim, :h pigeon.nvim
docs/               hawk.md, pigeon.md (user-facing), <name>/{design,glossary,gotchas}.md,
                    migration.md
tests/              one harness (minit.lua); tests/hawk/**, tests/pigeon/**
Makefile            check entrypoint
```

hawk and pigeon — the first two subsystems — arrive in the commits after the
repository skeleton; while a subsystem is absent, its line above is the target,
not a description.

## Commands

```sh
make check     # style + lint + test
make style     # stylua --check
make lint      # lua-language-server (every .lua file, tests/ included)
make test      # the mini.test suite (tests/**/*_spec.lua)
```

## Conventions

- **The public surface is `require("aviary").<subsystem>`.** A subsystem's
  internals import each other by full path (`require("aviary.hawk.git")`),
  never through the root: during a module's own load, going back through
  `require("aviary")` would re-enter it.
- **A new subsystem is a directory.** Adding one means `lua/aviary/<name>/`
  with its own `AGENTS.md`, config, public docs, and tests; the root module is
  not edited for it.
- **No user commands in the end state.** A subsystem exposes Lua functions.
  During the migration `:Hawk` and `:Pigeon` still exist; they are removed when
  the API is unified.
- **aviary never sets `_G`.** A user who wants a short name writes
  `_G.Aviary = require("aviary")` themselves.
- **Terminology lives in each subsystem's glossary.** Use its words in code,
  comments, docs, and commit messages; when a term changes, change the glossary
  in the same change.
- **Config is data.** A subsystem's `config.lua` carries the option table and
  its shape checks; what a value *selects* is resolved by the module that owns
  it.
- **Keep each subsystem's dependency direction.** hawk: view → model → source.
  pigeon: composition → commands → deliver → transport, and reference →
  formats.
- Lua 5.1 / LuaJIT only — Neovim's runtime; no features newer than 5.1.
- Every module is `local M = {}` … `return M`; imports use full module paths,
  sorted by module path.
- Public functions carry LuaLS annotations; a seam's contract types live with
  the seam, and options live in the subsystem's `config.lua`.
- Keep the public docs current in the same change: README, `docs/<name>.md`,
  and `doc/<name>.nvim.txt`.
- **User-facing docs say what, not why.** Rationale belongs in code comments or
  the subsystem's `docs/<name>/design.md`.
- Tests are `mini.test`, bootstrapped through `lazy.minit` into an isolated
  `.tests/`; `rm -rf .tests` asks for a fresh install.
