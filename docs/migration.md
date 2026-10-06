# Migration: hawk + pigeon → aviary

aviary is the merge of two plugins: hawk.nvim (a git change-set review) and
pigeon.nvim (send text to the window's other panes). The move is staged so that
every commit is verifiable on its own; the *merged design* — the
comment/extmark/tree integration, the unified API, the terminology — is
deliberately left to the stage after the move.

## Settled shape

- One plugin, one repository; `aviary` is the only module root.
- The subsystem set is open: a subsystem is a directory under `lua/aviary/`,
  and the root module is generic (`require("aviary").<name>`) rather than a
  fixed list.
- The public surface is `require("aviary").<subsystem>`; internals use full
  paths (`require("aviary.hawk.git")`).
- No user commands in the end state: subsystems are called from Lua.
- aviary never sets `_G`; a user may.
- The two subsystems keep their own design corpora, glossaries, and gotchas
  through the migration. `design.md` is split into `architecture.md` (the
  *what*) and `decisions.md` (the *why* and the reintroduction conditions) when
  the merged design is written.
- No remote for now; local verification first.

## Stage 0 — the repository

Tooling and the composition root, in one commit: `.gitignore`, `stylua.toml`,
`.luarc.json`, `LICENSE`, `Makefile`, CI, `tests/minit.lua`, `README.md`,
`AGENTS.md`, this file, `lua/aviary/init.lua`, and `tests/aviary_spec.lua`.

**Gate:** `make check` is green.

## Stage 1 — the subsystems move in

Each subsystem lands in its own commit (hawk first: its suite needs only git,
so it proves the harness before tmux is a dimension), behavior unchanged:

- `lua/<name>/**` → `lua/aviary/<name>/**`, every `require("<name>.…")`
  rewritten to `require("aviary.<name>.…")`.
- `tests/**` → `tests/<name>/**`; the subsystem's `minit.lua` is already the
  root's.
- `docs/**` → `docs/<name>/**`; `README.md` → `docs/<name>.md`;
  `AGENTS.md` → `lua/aviary/<name>/AGENTS.md`; `doc/<name>.nvim.txt` stays at
  the root and keeps its tags.
- The subsystem's own `Makefile`, `.luarc.json`, `stylua.toml`, CI, and
  `LICENSE` are not carried over: the root has its equivalents.
- `:Hawk` / `:Pigeon` stay; `:checkhealth <name>` becomes
  `:checkhealth aviary.<name>`.
- The subsystem's own `setup` stays the way to configure it:
  `require("aviary").hawk.setup({ ... })`.

**Gate:** hawk's `make test-hawk` is green and `:checkhealth aviary.hawk`
works; then pigeon's `make test` (its tmux specs included, unsandboxed) is
green and `:checkhealth aviary.pigeon` works.

## Stage 2 — the merge

Not designed yet. This stage carries, at least: removing `:Hawk` / `:Pigeon`
and exposing the Lua API; wiring `aviary.setup({ hawk = …, pigeon = … })` to
the subsystems' own setup; the comment/extmark/tree integration (a pigeon
comment is recorded as an extmark and shown in hawk's tree); the terminology
(review / mark / comment); the module map for the shared comment domain; and
the `architecture.md` + `decisions.md` split of the design corpora.
