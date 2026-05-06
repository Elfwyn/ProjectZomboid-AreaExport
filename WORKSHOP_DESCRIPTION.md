# Area Export

Admin-only migration utility for Project Zomboid Build 42.

Area Export lets server admins export a circular world area from one save or server and import it into another save at the original world coordinates. It is designed for base migration, server resets, recovery tests, and controlled admin workflows.

## Alpha Warning

Area Export is currently a first public alpha version. It can still contain bugs and can cause world-data problems if an import hits unsupported Project Zomboid object state. Always back up the target save and test on a local or disposable server before using it on a live server.

## What It Does

- Exports a circular footprint by center point and radius.
- Saves local export packages on the admin's PC.
- Lists local exports inside the Import tab.
- Imports at the original world coordinates and original radius stored in the export.
- Preserves many tiles, walls, doors, furniture, containers, stored items, loose floor items, player-built structures, and selected object state.
- Rebuilds interactive vanilla object classes for TVs, radios, stoves, microwaves, washers, dryers, BBQs, fireplaces, jukeboxes and composters instead of restoring them as static sprites.
- Supports a Validate / Dry Run page for item, sprite, and object conflicts before changing the target save.
- Shows package progress for Dry Run and Import.
- Automatically checks imported loose floor-item squares after import and removes client-side ghost items when the server confirms they no longer exist.

## Validate And Conflict Resolution

Dry Run streams the selected export package before import and does not change the save.

If an old export references item types that no longer exist, conflicts are grouped by missing item ID. One decision applies to all matching items:

- Replace: map every missing item type to a selected existing item type.
- Skip: drop every item of that missing type during import.
- Placeholder: keep a marker item so the conflict remains visible after import.

Sprite conflicts are lookup warnings. Use Original keeps the exported sprite name and is usually the correct default when source and target use the same mod set. Sprite conflicts can also be replaced or skipped. Object conflicts can be reviewed or skipped; incomplete legacy door data is reported separately.

Rules are staged for the next import in the current dialog session. Dry Run progress shows package tiles checked by the server while the client uploads the package.

## Special Object Notes

Project Zomboid gates many interaction menus behind Java object subclasses. A TV, radio, stove or dryer restored as a plain IsoObject can look correct but will not open its normal UI. Area Export now detects those classes during export and also infers them from sprite IsoType/container data during import for older packages. Generators, mannequins and feeding troughs remain state-heavy objects and are flagged by Dry Run object conflicts until separate state mapping is added.

Build 42 live imports also need targeted entity/component initialization for stoves, laundry machines, TVs and radios before the rebuilt object is transmitted. TVs and radios additionally need DeviceData from the tile CustomItem or matching TV/radio item type after object initialization, otherwise the sprite and IsoTelevision/IsoRadio class can persist but the device panel will not open.

Dedicated servers cache loaded Lua modules. After a mod update, restart the server process before retesting imports; reconnecting only the client does not reload server-side import code.

## Safety Notes

Importing is destructive inside the exported footprint. Existing objects in the target area are replaced by the export data. Always back up the target save and test on a disposable or local server before using this on a live server.

Do not import while players are active in the target area. Use one admin at a time for imports.

## Current Limitations

- Vehicles are not migrated.
- Zombies are not migrated.
- Player inventories are not migrated.
- Some state-heavy special objects, such as generators and mannequins, still need manual verification after import.
- Large radius exports/imports can take time and may briefly stall the game/server.

## Memory Notes For Large Exports

Export, Dry Run and Import use a package format instead of one giant JSON string.
Export writes tile JSON lines directly to disk on the admin PC through small raw
transfer parts. Dry Run streams those lines back to the server and scans one
tile at a time.

Import uploads the full package into a temporary server-side tile file first.
Only after that upload succeeds does the server clear and rebuild the target
footprint over later ticks. Very large areas can still take time and may briefly
stall while individual tiles with many objects or items are processed.

During clearing, linked vanilla double-door and garage-door parts are removed as
one group so partial door objects do not survive at footprint edges.

Live multiplayer door sync is conservative. Rebuilt doors are transmitted as
complete objects, but the mod avoids generic syncIsoObject packets for doors
because Build 42 can reject freshly rebuilt live door indexes even when the same
doors work after chunk reload. Garage door parts are restored as a closed linked
group instead of toggling each part during import.

Import progress is phase-based: client upload, target footprint clearing, then
server tile rebuild. The progress bar resets for each phase because each phase
has its own measurable total.

## Build Information

Built for Project Zomboid Build 42.

## Open Source

Area Export is open source:

https://github.com/Elfwyn/ProjectZomboid-AreaExport/

You may use the public code for your own mods, forks, variants, or compatibility patches. Reuse and adaptation are explicitly allowed and encouraged.

## Server Config

Workshop Item ID: `3718331659`

Mod ID: `AreaExport`

Server config:

```ini
WorkshopItems=3718331659
Mods=AreaExport
```

Maintainers: Area Export contributors
