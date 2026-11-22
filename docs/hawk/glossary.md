# Hawk glossary

| Term | Meaning |
| --- | --- |
| Review | A tab for comparing Git versions in a fixed worktree. |
| Snapshot | The comparison for one mode, including its input rows, latest change rows and title. |
| Metadata row | An input row that holds a draft value for the comparison. |
| Diff row | A file change with captured Git metadata and blob IDs for preview. |

Interface and lifetime contracts live in [Hawk and Tab](../../lua/aviary/hawk/init.lua)
and [Snapshot](../../lua/aviary/hawk/snapshot/init.lua). See the
[architecture](./architecture.md) for relationships and the
[manual](../hawk.md#review) for behavior.
