# Picker decisions

Interface and confirmation contracts belong to the
[picker entry](../../lua/aviary/weaver/picker/init.lua).
Configuration belongs in the [user manual](../weaver.md#files-and-buffers).

## Built-in file and buffer sources

File and buffer selection need discovery, previews and multiple selections, so
use the configured backend's built-in sources. Adopting backend defaults removes
the generic streaming source protocol and local process management. Finite
single-choice menus stay on vim.ui.select so they follow global UI configuration
independently of file selection.

## Buffer eligibility belongs to the picker entry

Both adapters must agree which buffers can supply file references, but vendor
item shapes differ. Keep the eligibility predicate in the picker entry and
translate vendor items inside each adapter, giving filtering one owner without
leaking backend formats.

## Private to Weaver

Files and buffers are currently the only selection needs, both owned by Weaver.
Keep implementation and configuration there rather than publishing a generic
picker interface. Extract it when another actual module needs the same ability.
