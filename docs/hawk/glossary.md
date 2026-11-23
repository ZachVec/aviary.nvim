# Hawk glossary

| Term | Meaning | Avoid |
| --- | --- | --- |
| Review | A tab for comparing Git versions in a fixed worktree. | |
| Snapshot | The comparison for one Review tab, including its input rows, latest change rows and title. | |
| Style | The comparison rule: `direct` compares `old` with `new`; `merge-base` compares their common ancestor with `new`. | mode |
| Mode | The snapshot implementation kind. Only `diff` exists now; `worktree` is planned. | style |
| Metadata row | An input row that holds a draft value for the comparison. | |
| Diff row | A file change with captured Git metadata and blob IDs for preview. | |

Interface and lifetime contracts live in [Hawk and Tab](../../lua/aviary/hawk/init.lua)
and [Snapshot](../../lua/aviary/hawk/snapshot/init.lua). See the
[architecture](./architecture.md) for relationships and the
[manual](../hawk.md#review) for behavior.
