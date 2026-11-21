# Neovim exports NVIM as a socket path to child processes. Use NVIM=nvim
# (or unset NVIM) when running make from inside Neovim.
NVIM ?= nvim
NVIM_LOG ?= /tmp/aviary-nvim.log
MASON_BIN ?= $(HOME)/.local/share/nvim/mason/bin

# Prefer PATH tools, then Mason.
find_tool = $(or $(shell command -v $(1) 2>/dev/null),$(if $(wildcard $(MASON_BIN)/$(1)),$(MASON_BIN)/$(1)))

STYLUA := $(call find_tool,stylua)
LUA_LS := $(call find_tool,lua-language-server)
MARKSMAN := $(call find_tool,marksman)

# Use this Neovim's runtime types so LuaLS can check vim.* calls.
NVIM_RUNTIME = $(shell $(NVIM) --headless -u NONE -i NONE -c 'lua io.write(vim.env.VIMRUNTIME)' -c 'qa' 2>/dev/null)

# Avoid cwd/nvim.log when the editor holds the default log lock.
NVIM_RUN = NVIM_LOG_FILE=$(NVIM_LOG) $(NVIM) --headless -u NONE -l

.PHONY: check style lint links docs-check test test-hawk test-pigeon

## check: Lua format + diagnostics + the mini.test suite + markdown links
check: style lint test links

## style: check Lua formatting (stylua)
style:
	@if [ -n "$(STYLUA)" ]; then $(STYLUA) --check .; else echo "note: stylua not installed; skipping Lua format check"; fi

## lint: check Lua diagnostics (lua-language-server)
## Include hints such as unused locals; _* locals are exempt.
lint:
	@if [ -n "$(LUA_LS)" ]; then VIMRUNTIME="$(NVIM_RUNTIME)" $(LUA_LS) --check="$(CURDIR)" --checklevel=Hint --configpath="$(CURDIR)/.luarc.json"; else echo "note: lua-language-server not installed; skipping Lua diagnostics"; fi

## links: check markdown doc links (marksman; skipped when it is not installed)
links:
	@if [ -n "$(MARKSMAN)" ]; then MARKSMAN="$(MARKSMAN)" $(NVIM_RUN) tests/doc_links.lua; else echo "note: marksman not installed; skipping markdown link check"; fi

## docs-check: generate user help and verify the Pandoc pipeline (requires pinned Pandoc)
docs-check:
	@./scripts/docs
	@bash tests/docs/generation

## test: run the mini.test suite (tests/**/*_spec.lua)
## Reuse .tests/ dependencies offline; the first run installs them.
test:
	@$(NVIM_RUN) tests/minit.lua --minitest --offline

## test-hawk: run only hawk's specs (tests/hawk/**/*_spec.lua)
test-hawk:
	@$(NVIM_RUN) tests/minit.lua --minitest --offline $(shell find tests/hawk -name '*_spec.lua' | sort)

## test-pigeon: live target routing and real tmux/Neovim Terminal specs (requires Unix sockets and python3)
test-pigeon:
	@$(NVIM_RUN) tests/minit.lua --minitest --offline $(shell find tests/pigeon -name '*_spec.lua' | sort)
