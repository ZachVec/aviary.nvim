# AGENTS.md

aviary is a Neovim plugin with public features and internal shared modules.

## Layout and boundaries

```text
lua/aviary/init.lua           composition root and lazy feature access
lua/aviary/<feature>/         public feature, entered through init.lua
lua/aviary/shared/<name>.lua  internal shared module; multi-file modules use <name>/init.lua with private implementation files
docs/<feature>.md             user manual
docs/<feature>/               selected developer documents
docs/shared/<name>/           selected shared-module developer documents
doc/                          generated user help
tests/<feature>/              feature specs
tests/shared/<name>/          shared-module specs
Makefile                      verification targets
```

- Features must not depend on other features; compose them at the root. Shared modules must not depend on features or form dependency cycles.

## Commands

Run from the repository root. Targets are defined in [Makefile](./Makefile).

```sh
make style          # Lua formatting
make lint           # Lua diagnostics
make links          # Markdown links
make docs-check     # Generate Vimdoc and test the pipeline; requires pinned Pandoc
make test-hawk      # Hawk specs
make test-weaver    # Weaver specs, including picker
make test-picker    # Weaver picker specs
make test-pigeon    # Pigeon specs, including tmux integration
make test-message   # shared.message specs
make test           # All specs
make check          # style + lint + test + links
```

For individual specs, replace the example path; multiple paths are accepted:

```sh
NVIM_LOG_FILE=/tmp/aviary-nvim.log nvim --headless -u NONE -l tests/minit.lua --minitest --offline tests/shared/path_spec.lua
```

- Match checks to changes: Lua edits need style, diagnostics, and relevant specs; Markdown edits need link checks; Vimdoc generation changes need `make docs-check`. Include affected callers and composition specs for cross-module behavior changes.
- Use full `make test` or `make check` only when explicitly requested, diagnosing CI failures, or narrower checks cannot adequately cover the change. Do not repeat passing checks without relevant changes or unresolved concerns.
- Inside Neovim, use `make NVIM=nvim <target>` to override the inherited socket-valued `NVIM`. Tmux integration tests require Unix-socket access and Python 3.

## Conventions

- **Zero Overheads.** Don't pay for what you don't use; what you do use, you couldn't hand-code any better.
- **Write annotations.** Declare table types and members once at file top; use inline function types for function members and documentation tags directly above standalone functions.
- **Enforce invariants by design.** Establish contracts through types, visibility, and API design.
- **Trust Contracts.** Treat annotations and API contracts as enforced. Callers satisfy them; callees do not recheck them. Let violations fail naturally.
- **Let exceptions propagate.** Catch only to perform necessary failure handling, not merely to convert exceptions into return values.
- **Validate untrusted boundaries.** Repository code, Neovim APIs (including overrides), and dependencies explicitly required by this repository are trusted. Validate untrusted external data and values received from other external code at entry.
- **Optional parameters take `?` on the name, not the type:** write `---@param name? string`, never `---@param name string?`.
- **Acquire resources transactionally.** Use the shared [transaction module](./lua/aviary/shared/transaction.lua) for fallible multi-step acquisition.
- **Keep configuration as data.** Put configuration and shape validation in `config.lua`. Non-root `setup` only merges options over defaults, validates, and updates its own running configuration. Resolve selected behavior when used.
- **Keep comments local.** Do not restate code, expand unrelated comments, or explain distant behavior without local need rationale.
- **Tests specify intended behavior.** When intended behavior changes, update the tests and explain why in the PR.
- **Keep work notes local.** Store specs, tickets, task progress, troubleshooting history, and review responses as Markdown in `.scratch/<feature-slug>/`.

## Documentation

- Start with module entries and types, then read relevant docs before designing.
- Choose the location by the reader's question, not content length or file count.
- Store complete definitions, contracts, and rationale once; elsewhere, use necessary summaries and inline Markdown links with explicit relative targets.
- Update affected contracts and docs with code; remove obsolete content and keep terminology consistent.
- Add information that names, types, and code leave unstated. Do not require prose for every function or developer docs for every module.

### Source comments

- Document caller contracts at module entries and in type/member/function annotations: inputs, outputs, preconditions, side effects, errors, and ordering.
- Include ownership, borrowing, mutability, and cancellation requirements.
- Callers must be able to use the interface correctly without reading implementation or architecture.
- State common obligations once on their owning type or module.
- Add minimal examples when they clarify the interface.
- Put module-wide implementation invariants at the source entry; local mechanisms, reasons, and external limitations beside the code they constrain.
- Put design rationale meeting the Decisions criteria in decisions.

#### Interface contracts

Evaluate each statement for the current module and its direct caller. Include it in the interface contract only when all three apply:

- The caller needs it to prepare inputs, arrange calls, handle results, or judge suitability; understanding implementation alone is insufficient.
- Preconditions are the caller's responsibility; guarantees are the module's responsibility. Dependency assumptions and callers' recovery policies do not automatically belong here.
- It uses this interface's concepts and remains valid when the implementation changes without changing the interface's promises.

For statements that do not qualify:

- Keep internal mechanisms and assumptions with their implementation; explain cross-module collaboration in architecture.
- Do not hide real limitations by moving or deleting comments. Review any new caller obligation as an interface design change.
- Backend names and environment requirements may appear where configuration exposes them. Judge responsibility, not technical vocabulary.

### User documentation

- `README.md` is the quick start; `docs/<feature>.md` is the manual. New features need both.
- Cover installation, dependencies, configuration, defaults, examples, and user-visible behavior and limitations.
- Users must not need source or developer docs. Repeat user-visible contracts as needed.
- Put implementation explanations in source or developer docs.
- Edit Markdown; CI generates Vimdoc from README and user manuals. Developer documents are excluded.

### Architecture

- Explain how parts work together: responsibilities, dependencies, data/control flow, and state/resource ownership and lifetimes.
- Organize around relationships and runtime flows, including those within one file. Avoid exhaustive file-by-file or method-by-method tours.
- Add architecture docs when relationships need more than a source-entry overview; update inaccurate diagrams and explanations.
- Summarize contracts only as needed to explain a relationship; link to the owning source without copying the full contract.
- Keep calling instructions, parameter/return/option tables, and standalone usage recipes in source comments or user manuals.
- Keep local implementation explanations beside code, concept definitions in glossary, and design trade-offs in decisions.

### Glossary

- Describe project-specific concepts in one or two sentences.
- Give each concept one canonical name; list rejected synonyms under `_Avoid_`.
- Add terms as soon as their meaning and name are settled.
- Immediately point out wording or behavior claims that conflict with existing glossary definitions or code.
- Resolve vague, overloaded, or conflicting terms through concrete examples; check the result against code.
- Exclude general programming concepts, specifications, implementation details, design decisions, and session notes.

### Decisions

Capture a design choice, its context, and its rationale in one to three sentences. Propose a new record only when all three apply:

- Reversing the choice would have meaningful cost.
- The choice would be surprising without context.
- There were genuine alternatives and trade-offs.

### Placement review

Review added or revised prose before finishing a change:

- Apply the interface-contract criteria before moving conditions to module entries.
- Ensure every required calling condition is in the source entry or its types; architecture must not be its only location.
- Check that each architecture paragraph explains a relationship or runtime flow. Move pure calling/configuration guidance to source comments or user documentation.
- Separate passages answering different questions and move each explanation to its owning location.
- Replace redundant full explanations with summaries and links; keep repeated user-visible facts consistent.
