# Hawk decisions

Interface contracts belong to the [Hawk entry](../../lua/aviary/hawk/init.lua),
[Review UI entry](../../lua/aviary/hawk/review/init.lua) and
[Review data entry](../../lua/aviary/hawk/review/review.lua).
See the [architecture](./architecture.md) for collaboration and lifetimes.

## One concrete Review instance

Review is Hawk's only UI workflow, so one concrete ReviewTab owns the list and both
version panes. A feature registry or generic list parent would add selection and
inheritance contracts without another consumer, while separate pane lifetimes
could leave a live list holding invalid buffer IDs.

## Construction and closure have separate scopes

Build the complete UI synchronously in one transaction and publish it only after
success, so callers never own a partial Review. Normal closure ends Lua state
immediately and defers native reclamation until the initiating window/buffer
operation finishes. Retaining the transaction as a destructor would mix rollback
focus restoration with ordinary cleanup and retain the ended object.

## Review composes native resource factories

Review composes native acquisition/rollback pairs instead of depending on a shared
layout descriptor. This keeps geometry and successful lifetime policy with the UI
owner while resource factories remain reusable across features.

## Lists retain original items

Snapshots retain original Changes rather than formatted rows, so width changes
can redraw without querying data or replacing item identity. Formatting stays on
Change, keeping window measurement and UI state out of the rendering contract.

## The UI owns query flows

Metadata, body and revision-candidate queries run in UI-started flows; queries
borrow their context and return data. This keeps query, parsing and UI-update
errors in one failure path instead of forwarding completion callbacks through
data layers. Metadata and body cancellation remain independent so list refresh
cannot interrupt the versions being inspected.

## Captured versions and live comparison choices

Each Change captures blob IDs and revision labels so later ref/index movement
cannot change the versions represented by that row. An omitted base resolves HEAD
on each read instead of caching a SHA, allowing the default to follow commits and
branch switches. Explicit comparison choices remain session state so closing and
reopening Review preserves the user's selection.

## Git queries return owned data

The Git module returns parsed owned results rather than command descriptions or
raw stdout. Keeping command construction, execution options and protocol parsing
there removes Git framing knowledge from Review and the UI.

## Observation follows the UI lifetime

Repository observation follows Review because a closed UI has no metadata cache
to maintain. A per-UI stop function supports rollback and closure without
session-wide background work, subscriber tracking or reference counts.

## Resolve the repository at operation entry

Repository presence can change without DirChanged, such as Git initialization in
the current directory. Resolve the root at operation entry and capture it for the
flow instead of trusting an observation cache, so manual refresh remains useful
independently of the watch.
