# Hawk glossary

| Term | Meaning |
| --- | --- |
| Review | Hawk's single reusable Git review interface. |
| Change | Captured Git change metadata with fixed blob IDs and revision labels, identifying the file versions represented by a review row. |

Interfaces and lifetime contracts live in the
[Hawk entry](../../lua/aviary/hawk/init.lua) and
[Review entry](../../lua/aviary/hawk/review/init.lua).
See the [architecture](./architecture.md) for collaboration and resource lifetimes.
Review behavior is described in the [manual](../hawk.md#review).
