# Testing

Choose coverage by supported behavior, regression risk, and existing tests. Users include both plugin users and callers of internal modules.

## Select coverage

- For new or changed behavior and bug fixes, identify the behavior to protect and a plausible failure. Reuse sufficient existing coverage. Where coverage is missing, weigh failure impact, recurrence risk, and test maintenance cost; a gap alone does not require a new test.
- Low-risk, localized fixes that are easy to verify directly may skip new cases even when coverage is incomplete. Behavior-preserving refactors and documentation or formatting changes usually need only relevant existing checks.
- Prioritize important behavior and subtle or widespread failures, including meaningful input boundaries, failure recovery, cancellation, state transitions, asynchronous ordering, and resource rollback or cleanup. Choose cases for distinct behavior or failure risks rather than every possible input combination.
- Do not allocate a test per function or add assertions solely to increase coverage numbers. An uncovered line may be dead code rather than a missing test.
- Trust annotated internal inputs and dependency contracts. Cover validation of untrusted external data and failures allowed by dependency contracts; do not invent internal contract violations or separately prove trusted dependencies work.
- Inject exceptions only to model realistic supported failures or verify an explicit failure-handling contract. Do not create new recovery requirements by making trusted Neovim APIs or unrelated autocmds throw. Callbacks that fail the test on unexpected events remain valid assertions.
- Add performance tests when there is a concrete budget or regression to protect.

## Choose the test level

- Test independent algorithms, parsers, and state machines through their module interfaces. Internal modules can merit direct tests without going through the plugin root.
- Use focused real-Neovim tests for editor interactions and key cross-module workflows. Check actual text, cursor or mode, windows, focus, highlights, files, or delivered content. Use screen comparisons when presentation is part of the behavior.
- Cover detailed input combinations through the smallest module interface that exposes the behavior. Use integration tests for distinct wiring or environment risks, without repeating every input case at every level.
- Keep owned modules real where practical. Replace external, costly, or nondeterministic dependencies only as needed; substitutes must satisfy the original interfaces.
- Include supported-version or platform checks when behavior depends on Neovim internals or platform differences.

## Keep assertions meaningful

- Check results and effects that callers rely on. Avoid assertions tied to private representations, helper decomposition, or incidental call counts and order; assert ordering when it is itself a promised behavior.
- Derive expected results independently. Simple reference implementations are useful; copying the production algorithm or calling the tested function to generate its own expectation is not.
- A regression test should detect the faulty behavior and pass after its correction. Tests for new behavior need not wait for a reported bug.
- Update obsolete expectations when intended behavior changes. Keep cases deterministic, restore modified editor state, and release test-owned resources even on failure.
