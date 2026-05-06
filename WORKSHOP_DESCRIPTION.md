# Area Export

Admin-only migration utility for Project Zomboid Build 42.

Area Export lets server admins export a circular world area from one save or server and import it into another save at the original world coordinates. It is designed for base migration, server resets, recovery tests, and controlled admin workflows.

## What It Does

- Exports a circular footprint by center point and radius.
- Saves export JSON files locally on the admin's PC.
- Lists local exports inside the Import tab.
- Imports at the original world coordinates and original radius stored in the export.
- Preserves many tiles, walls, doors, furniture, containers, stored items, loose floor items, player-built structures, and selected object state.
- Supports a Validate / Dry Run page for item conflicts before changing the target save.
- Automatically checks imported loose floor-item squares after import and removes client-side ghost items when the server confirms they no longer exist.

## Validate And Item Correction

Dry Run reads the selected export before import and does not change the save.

If an old export references item types that no longer exist, conflicts are grouped by missing item ID. One decision applies to all matching items:

- Replace: map every missing item type to a selected existing item type.
- Skip: drop every item of that missing type during import.
- Placeholder: keep a marker item so the conflict remains visible after import.

Rules are staged for the next import in the current dialog session.

## Safety Notes

Importing is destructive inside the exported footprint. Existing objects in the target area are replaced by the export data. Always back up the target save and test on a disposable or local server before using this on a live server.

Do not import while players are active in the target area. Use one admin at a time for imports.

## Current Limitations

- Vehicles are not migrated.
- Zombies are not migrated.
- Player inventories are not migrated.
- Some special object state may still need manual verification after import.
- Large radius exports/imports can take time and may briefly stall the game/server.

## Build Information

Built for Project Zomboid Build 42.

## Open Source

Area Export is intended to be open source. Source code is available on GitHub when linked from the Workshop page.

You may use the mod sources for your own mods, forks, variants, or compatibility patches. Reuse and adaptation are explicitly allowed and encouraged.

Maintainers: Area Export contributors
