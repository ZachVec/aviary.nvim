# Hawk decisions

See the [architecture](./architecture.md) and the interface contracts in
[Hawk and Tab](../../lua/aviary/hawk/init.lua).

## One worktree per tab

A Tab fixes its worktree when opened. Independent instances let users keep
multiple comparisons side by side and keep revision choices associated with the
worktree that interprets them.

## Separate draft input from the displayed comparison

Metadata rows hold drafts. A successful Git query updates the comparison and
its title, so users can correct an invalid draft while seeing the last successful
result.

## Construction and closure have separate scopes

Synchronous construction acquires the full layout and rolls it back on failure.
Normal closure ends Lua state immediately and defers native reclamation so the
initiating window or buffer operation can finish. The rollback transaction may
restore focus, so its lifetime ends with construction.

## The UI owns query flows

List and preview queries borrow the context of their respective Tab-owned
flows. Separate cancellation lets users refresh the list while continuing to
inspect the represented versions.

## Capture file versions at comparison time

A change row keeps the blob IDs captured by the comparison. Preview continues
to show the selected versions when Git refs move.
