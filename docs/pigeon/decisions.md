# Pigeon decisions

Interface contracts belong to the [Pigeon entry](../../lua/aviary/pigeon/init.lua)
and [backend entry](../../lua/aviary/pigeon/backends/init.lua).
See the [architecture](./architecture.md) for collaboration and resource lifetimes.

## Receivers and views share the host server

Tool input should inherit the user's tmux settings, so receivers and views share
Neovim's host server. This avoids option snapshots, synchronization and a private
server with different extended-key behavior. User hooks and shared server options
are deliberately allowed to affect receivers.

## Native receiver identity and discovery

Receiver identity must survive rediscovery and window renames, so use a timestamp
session name for identity and @pigeon_tool for ownership/tool selection. This
avoids stale Targets aliasing reused pane IDs and removes window-name stability
from discovery. Read launch cwd from pane_start_path so another editor can recover
reference context without Lua state even after the agent changes directory.

## Current is a selected reference

A receiver can exit between a check and its use, so current remains a destination
reference and normal operation failure ends the request. Liveness watchers and
preflights cannot guarantee delivery; automatic retries could replay content the
user did not ask to resend.

## Views are disposable resources

Editors can share a tmux window and users can close floats manually, so CLI
rediscovers views by their source mark on each show. New and reused views share
one configuration/rollback scope, leaving the receiver and draft available if a
view fails. Cached pane IDs or a separate rollback policy for reused views would
add stale state or preserve partially configured displays.

## Evaluate before delivery

Reference spelling needs the selected destination's cwd and formatter, so Messages
retain captured values until Target evaluation. Complete evaluation precedes all
writing, preventing a failed node from delivering part of a composite Message.

## Tmux resolves dimensions

Store width and height as native tmux dimension strings and resolve geometry on
each show. Computing cell counts in Lua would couple configuration to captured
window geometry and duplicate tmux's layout policy.

## A dedicated shared receiver key table

Hosted receivers need a close binding without rewriting the user's root/global
maps. Use one shared aviary-pigeon key table, accepting the latest show's close
key across receivers instead of maintaining per-receiver binding state.
