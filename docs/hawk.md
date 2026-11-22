# Hawk

<!-- vimdoc: hawk.show() aviary.hawk.show() -->

Hawk reviews Git versions in a dedicated tab.
Staging, committing, pushing and creating PRs remain with your existing Git tools.
See [installation](../README.md#installation) and
[requirements](../README.md#requirements).

```lua
require("aviary").hawk.show()
```

Each call opens a new Review tab. Review takes the Git worktree from Neovim's
global cwd at opening. The current file, `:lcd` and `:tcd` do not affect it.
Later `:cd` calls affect where new Reviews open. Outside Git, Hawk warns and
leaves the current tab in place.

## Review

The bottom buffer starts with empty `old` and `new` inputs, followed by the
change list. The initial mode is direct.

The `hawk` action opens `vim.ui.input()` on an input row and opens a preview
on a change row. Enter invokes this action by default. Confirming applies the
value to the row that opened the prompt. An empty or whitespace-only input
clears the value. Cancelling preserves the draft.

Each side accepts a Git revision such as a branch, tag, commit SHA or `HEAD~2`.
Git resolves both revisions on each refresh, including `HEAD` in a detached
worktree. An unborn `HEAD` causes a Git error when the comparison uses it.

| Key | Action |
| --- | --- |
| Enter | Run `hawk` on the current row |
| `r` | Refresh the list using both input values |
| `q` | Close Review |

Both inputs must have a value for the refresh to run. Edits, repository changes
and moving between tabs leave the list as shown until the next manual refresh.
A failed Git query displays Git's diagnostic and leaves the drafts, last list
and previews available. Fix the draft and press `r` again.

Direct mode compares `old` with `new`. Merge-base mode compares their common
ancestor with `new`. For example, `main → HEAD` in merge-base mode shows
changes from the branch's fork point. Unrelated histories report a Git error.
Switching modes keeps both drafts and clears the list. Press `r` to run the
new comparison. The configuration example below adds mappings for both modes.

The initial list title is `Review #{id}`. After a successful comparison it
includes the mode, `old` and `new`. The mode is  for direct and 󰓁 for
merge-base. Commit hashes in titles are abbreviated to seven characters.

Change rows display repository-relative paths in order.
Each row shows status, full path and added/deleted line counts, such as
`M lua/aviary/hawk/init.lua +12 -3`. Renames display both paths. Counts use
`10k+` at 10000 lines or more. Long rows follow the window's `wrap` setting.

`hawk` on a change loads the selected file into the readonly `old` and `new`
windows and keeps the focus in the list. Both previews start at the top of the
file and use the blobs captured at refresh. Refresh leaves the displayed
previews in place. Binary and submodule entries show a description in each
pane. Selecting another item or closing the tab cancels pending preview reads.

Preview buffer names use the tab ID and side, as in `2:old/lua/main.lua` and
`2:new/lua/main.lua`. Renames use the original path on the left and the new path
on the right.

## Buffers and windows

<!-- vimdoc: hawk.nvim-buffers -->

Review owns two readonly version windows above a full-width readonly list. All
three windows use `winfixbuf`. The version windows use Neovim diff.

Complete UI creation is transactional. Failure cleans up the attempt and
restores the source window. Closing any owned window or wiping an owned buffer
ends Review and cancels pending reads. Last-tab closure uses native `qall` with
unsaved checks and confirmation. Each new Review starts with empty inputs.

## Configuration

```lua
require("aviary").setup({
  hawk = {
    keymaps = {
      close = { "q" }, hawk = { "<CR>" }, refresh = { "r" },
    },
    actions = {},
  },
})
```

Each key array replaces defaults. Use `{}` to disable an action's keys. To
change the keys for the row action, set `hawk.keymaps.hawk`. To override how
the row action handles input or previews, supply `hawk.actions.hawk`. Actions
can also supply handlers for custom mappings. Review installs the mappings in
its list buffer when it opens.

Actions receive the owning Tab. An input callback can use the row captured when
the prompt opened while that row still belongs to the open Tab.

| Method | Behavior |
| --- | --- |
| `tab:current()` | Return the selected row and its one-based buffer line. A `meta` row exposes `label`, `value` and `input`. A `diff` row exposes `path` and the change metadata. |
| `row:edit(value)` | Update a metadata row's draft with a single-line string. Follow with `tab:render(lnum - 1, lnum)` to redraw that row. |
| `row:jump(tab)` | Preview a diff row |
| `tab:render(first, last)` | Redraw a zero-based half-open range of list lines. Use `-1` for the end of the list. |
| `tab:refresh()` | Refresh the comparison using both inputs |
| `tab:close()` | Close the Review |
| `tab:to(style)` | Switch to `"direct"` or `"merge"`. Selecting the current mode has no effect. |

For example, bind each comparison mode and add an action that shows the
selected path.

```lua
require("aviary").setup({
  hawk = {
    keymaps = {
      direct = { "<leader>hd" },
      merge = { "<leader>hm" },
      show_path = { "<leader>hp" },
    },
    actions = {
      direct = function(tab) tab:to("direct") end,
      merge = function(tab) tab:to("merge") end,
      show_path = function(tab)
        local row = tab:current()
        if row.kind == "diff" then
          vim.notify(row.path)
        end
      end,
    },
  },
})
```

Full contracts live in [Hawk and Tab](../lua/aviary/hawk/init.lua)
and [Row](../lua/aviary/hawk/snapshot/row.lua).

The former `common` and `review` configuration sections are replaced by
`hawk.keymaps` and `hawk.actions`. Feature names and `select_feature` are removed;
use `aviary.hawk.show()` without arguments, replacing the root `review()` action.
The input fields replace the old version picker and its `b`, `B`, `f` and `F` bindings.

There is no custom highlight configuration. The former comments feature and
`hawk.comments` options have been removed.

<!-- vimdoc: hawk.nvim-health -->

`:checkhealth aviary.hawk` reports Git availability for Review.
