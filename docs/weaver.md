# weaver

Capture editor input, compose Messages, and send them through Pigeon. See
[installation](../README.md#installation) and [requirements](../README.md#requirements).

## Usage

<!-- vimdoc: weaver.nvim-api weaver.prompt() aviary.weaver.prompt() weaver.files() aviary.weaver.files() weaver.buffers() aviary.weaver.buffers() weaver.text() aviary.weaver.text() -->

```lua
local aviary = require("aviary")
aviary.weaver.prompt()  -- choose a named template and send it
aviary.weaver.files()   -- choose file references and send them
aviary.weaver.buffers() -- choose buffer references and send them
aviary.weaver.text()    -- send selection or current line
```

All four actions take no arguments and return nothing. They send complete
Messages through Pigeon's current/default target. Cancellation sends nothing.
`text` captures and sends immediately, including an empty line; selectors send
after confirmation. Startup and resolver errors propagate; delivery failures
follow [Pigeon's notification contract](./pigeon.md#usage).

For example:

```lua
vim.keymap.set("n", "<leader>af", function()
  require("aviary").weaver.files()
end)
vim.keymap.set({ "n", "x" }, "<leader>at", function()
  require("aviary").weaver.text()
end)
vim.keymap.set({ "n", "x" }, "<leader>ac", function()
  require("aviary").weaver.prompt()
end)
```

## Templates

`prompt()` selects a named template through `vim.ui.select`. Built-in
placeholders are `{file}` (invoking filename) and `{line}` (filename and current
line or active Visual whole-line range). Characterwise, linewise and blockwise
Visual selections use their inclusive first and last rows. A single row keeps
the same format as a Normal-mode cursor line.

Capture exits Visual mode before opening the template picker. Use a Lua callback
or `<Cmd>` Visual mapping to retain the active selection until capture. The
Selection and prompt configuration are captured before opening the picker. Later
focus, source edits, renames or deletion do not change the captured Selection;
setup changes apply to the next invocation. The target applies its own cwd and
reference formatter.
Tokens without a configured resolver are sent verbatim. Literal spacing,
punctuation, percent signs and newlines are preserved. The two built-in templates
include one trailing space after their placeholder. An unnamed file produces
an unresolved Reference; evaluation fails without returning partial text.

```lua
require("aviary").setup({
  weaver = {
    picker = "snacks", -- snacks | fzf-lua
    prompts = {
      ["{file}"] = "{file} ",
      ["{line}"] = "{line} ",
      review = "Review {file} for bugs.",
    },
    references = { join = "\n" },
  },
})
```

Named templates merge additively with the two built-ins. A matching name replaces
its template. `references.join` separates selected file/buffer references.

Unknown options and unknown fields under `references` are rejected; prompt names
and resolver names are user-defined. `weaver.setup(opts)` returns `false, reason`
on invalid options and keeps the previous configuration. See [setup scope](../README.md#installation)
for which features reset through root and direct feature setup.

### Resolvers

`resolvers` maps token names without braces to `function(selection) -> Message`.
Names in templates use letters, digits and underscores. Custom entries merge
with the built-in `file` and `line` resolvers; matching names override them.

Each resolver receives the same captured Selection: `path` is the absolute
filename (empty for an unnamed buffer), `start_row` is the inclusive first row,
and `end_row` is the inclusive last row, omitted for a single row. Keep this
borrowed value unchanged. See the [Selection contract](../lua/aviary/weaver/init.lua).

```lua
local Message = require("aviary.shared.message")
require("aviary").setup({
  weaver = {
    prompts = { review = "Review {line} ({rows} lines)." },
    resolvers = {
      rows = function(selection)
        local last = selection.end_row or selection.start_row
        return Message.text(tostring(last - selection.start_row + 1))
      end,
    },
  },
})
```

After confirmation, only the chosen template is expanded, in token order, once
per occurrence. Resolvers may return any [Message](./shared/message/glossary.md),
including a composite, and may read other state when called. Cancellation calls
no resolvers. Resolver exceptions propagate without delivering a partial Message.

## Files and buffers

`files()` selects files under global cwd (`:cd`), following symlinks.
`buffers()` selects named, listed, normal buffers backed by readable files. Buffers
outside cwd remain selectable. Results contain references, not buffer contents.

| `weaver.picker` | Dependency |
| --- | --- |
| `snacks` (default) | [snacks.nvim](https://github.com/folke/snacks.nvim) |
| `fzf-lua` | [fzf-lua](https://github.com/ibhagwan/fzf-lua) |

The selected picker provides discovery and previews. Each confirmation captures
the selected paths and separator and delivers a complete Message after picker
cleanup. Resuming and confirming the picker sends a new Message through Pigeon's
current target at delivery time.
Prompt choices follow the global `vim.ui.select` configuration independently of
the file/buffer picker.

## Selected text

`text()` captures whole lines from the active Visual range, otherwise the cursor
line. Capturing exits Visual mode. Use a Lua callback or `<Cmd>` Visual mapping
to retain the active selection until capture.
Text is verbatim, including empty text, with no placeholder expansion.

## Health

Run `:checkhealth aviary.weaver` for Neovim, picker selection and prompt count.
Receiver configuration and tool launching belong to [pigeon](./pigeon.md).
