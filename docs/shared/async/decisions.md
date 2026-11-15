# Async decisions

Interface contracts and cancellation limits belong to the
[module entry](../../../lua/aviary/shared/async.lua).
See the [architecture](./architecture.md) for execution and termination flows.

## Separate process startup from waiting

Review needs two independent blob reads, so separate process startup from waiting
to express concurrency in ordinary control flow. An explicit context identifies
the owning flow without a global registry, task tree or parallel-combinator
interface. Dependent commands still sequence naturally through run followed by
wait.

## Work owns success, on_error owns failure

Keep successful result handling inside work and expose only an optional failure
handler, so sequencing, parsing and UI updates share one failure path. Default
notification makes deferred failures visible because a pcall around startup
cannot catch them. This avoids success/error callback forwarding through callers
that already own the work.

## Jobstart and complete output

Commands need flow-owned process-group/tree cancellation, so use jobstart rather
than vim.system's direct-child kill interface. Consumers need complete file
contents, so collect both streams into one result instead of maintaining a
streaming queue or general scheduler.
