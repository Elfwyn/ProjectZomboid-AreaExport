# Area Export

Admin-only migration utility mod for Project Zomboid Build 42.

Area Export exports a circular world area to local JSON and imports it into another save or server at the original world coordinates. It is intended for base migration, server resets, recovery testing, and controlled admin workflows.

- Mod ID: `AreaExport`
- Maintainers: Area Export contributors
- Version: 1.0.0
- Access level: Admin
- Target build: Project Zomboid Build 42

## Features

- Export by center point and radius.
- Local export library stored on the admin PC.
- Import at the original coordinates and original radius stored in the export.
- Preserve many tiles, walls, doors, furniture, containers, stored items, loose floor items, player-built structures, and selected object state.
- Validate / Dry Run page for grouped import conflicts before changing save data.
- Item correction rules for missing or renamed item types: replace, skip, or keep placeholder.
- Automatic post-import reconcile for loose floor-item client ghosts.
- Multiplayer workflow through server-side import/export commands.

## Installation

Copy or subscribe to the mod, then enable `Area Export` on the client and the server.

Local development install:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/local-install.ps1
```

## Usage

1. Join as an admin.
2. Open the Area Export admin tool.
3. In Export, click `Pick Center`, select the middle tile, enter a radius, then click `Preview`.
4. Enter a name prefix and click `Export`.
5. On the target save or server, open Import and select the local export.
6. Click `Validate` for a dry run.
7. Resolve grouped item conflicts if needed.
8. Click `Import`.
9. Reconnect or restart the client if Project Zomboid has not redrawn changed chunks.

Exports are stored under:

```text
Zomboid/Lua/AreaExportClient/
```

The export list is stored in `index.json`. Individual exports are JSON files next to that index.

## Validation And Item Correction

Dry Run reads the selected export and does not change the save.

Missing or renamed item types are grouped by old item ID. One rule applies to all matching items:

- `Replace`: maps every missing item type to a selected existing item type.
- `Skip`: drops every item of that missing type during import.
- `Placeholder`: keeps a marker item so the conflict remains visible after import.

Object conflicts can currently be reviewed or skipped. Automatic object replacement is intentionally not attempted.

## Safety

Importing is destructive inside the exported footprint. Existing objects in the target area are replaced by the export data.

Always back up the target save before importing. Test every migration on a local or disposable server before using it on a live server. Do not import while players are active in the target footprint.

Server-side command handling requires admin access. Large local-copy uploads are bounded server-side to reduce accidental misuse.

## Current Limitations

- Vehicles are not migrated.
- Zombies are not migrated.
- Player inventories are not migrated.
- Some special object state may still need manual verification after import.
- Large radius exports/imports can take time and may briefly stall the game/server.

## Project Structure

```text
Contents/mods/AreaExport/
  42/
    mod.info
    media/lua/client/AreaExport/
    media/lua/server/
    media/lua/shared/AreaExport/
workshop.txt
WORKSHOP_DESCRIPTION.md
```

## Open Source

Area Export is intended to be open source. Source code is available on GitHub when linked from the Workshop page.

You may use the mod sources for your own mods, forks, variants, or compatibility patches. Reuse and adaptation are explicitly allowed and encouraged.
