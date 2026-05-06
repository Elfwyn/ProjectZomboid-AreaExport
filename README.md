# Area Export

Admin-only migration utility mod for Project Zomboid Build 42.

Area Export exports a circular world area to a local package and imports it into another save or server at the original world coordinates. It is intended for base migration, server resets, recovery testing, and controlled admin workflows.

> Alpha warning: Area Export is currently a first public alpha version. It can still contain bugs and can cause world-data problems if an import hits unsupported Project Zomboid object state. Always back up the target save and test on a local or disposable server before using it on a live server.

- Mod ID: `AreaExport`
- Steam Workshop Item ID: `3718331659`
- Maintainers: Area Export contributors
- Version: 1.0.0
- Access level: Admin
- Target build: Project Zomboid Build 42

## Server Config

Use these values in the Project Zomboid server config:

```ini
WorkshopItems=3718331659
Mods=AreaExport
```

## Features

- Export by center point and radius.
- Local export package library stored on the admin PC.
- Import at the original coordinates and original radius stored in the export.
- Preserve many tiles, walls, doors, furniture, containers, stored items, loose floor items, player-built structures, and selected object state.
- Rebuild interactive vanilla object classes for doors, windows, light switches, TVs, radios, stoves, microwaves, washers, dryers, BBQs, fireplaces, jukeboxes and composters.
- Validate / Dry Run page for grouped import conflicts before changing save data.
- Conflict resolution for missing item types, sprite lookup warnings, unsupported object classes, and incomplete legacy door data.
- Item correction rules for missing or renamed item types: replace, skip, or keep placeholder.
- Sprite warning rules: use original, replace, or skip.
- Automatic post-import reconcile for loose floor-item client ghosts.
- Multiplayer workflow through server-side streaming import/export commands.

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

The export list is stored in `index.json`. Current exports are stored as a small
`*.manifest.json` file plus a streamed `*.tiles.jsonl` tile file next to that
index. The UI reads only index/manifest metadata when opening, refreshing or
selecting exports.

## Export Metrics

Preview separates map structure from items so large exports are easier to read:

- `Map tiles`: loaded squares saved into the package.
- `Map objects`: normal world objects on those tiles, such as walls, doors, windows, furniture and fixtures.
- `Containers`: world objects that expose an item container.
- `Container items`: items stored inside those containers.
- `Loose floor items`: world inventory items lying on the ground.
- `Total item records`: container items plus loose floor items.

During streaming export the progress bar is based on scanned map positions in
the circular footprint across z-levels 0 through 7. `Transfer parts` are only
network/file-transfer pieces sent from the server to the client; they are not
map chunks and their final count is only known once the stream is complete.

## Special Object Rebuild

Project Zomboid uses Java subclasses for many interactive fixtures. A TV saved
back as a plain `IsoObject` can look correct but will not open the device panel;
the same applies to radios, stoves, microwaves, washers, dryers and similar
fixtures. Area Export therefore stores detected subclasses where possible and
also falls back to sprite `IsoType` and container type during import for older
packages.

Build 42 also initializes live interaction through entity/components while
placing moveables. Imported stoves, laundry machines, TVs and radios must run
the same cell-loading initialization before they are transmitted, otherwise they
may persist correctly but remain non-interactive. TVs and radios additionally
need script-backed `DeviceData` from the tile `CustomItem` or matching TV item
type after object initialization. The visible TV sprite and `IsoTelevision`
class alone are not enough for the radio/TV panel.

Dedicated servers cache loaded Lua modules. After updating this mod, restart the
server process before running another import; reconnecting only the client does
not reload server-side import code.

Current safe rebuild classes include `IsoDoor`, `IsoWindow`, `IsoLightSwitch`,
`IsoStove`, `IsoTelevision`, `IsoRadio`, `IsoClothingWasher`,
`IsoClothingDryer`, `IsoCombinationWasherDryer`, `IsoBarbecue`,
`IsoFireplace`, `IsoJukebox` and `IsoCompost`. More state-heavy classes such as
generators, mannequins and feeding troughs are flagged by Dry Run object
conflicts until they get separate state mapping.

## Validation And Conflict Resolution

Dry Run reads the selected export and does not change the save.

Missing or renamed item types are grouped by old item ID. One rule applies to all matching items:

- `Replace`: maps every missing item type to a selected existing item type.
- `Skip`: drops every item of that missing type during import.
- `Placeholder`: keeps a marker item so the conflict remains visible after import.

Sprite conflicts are lookup warnings, not always hard incompatibilities. When the source and target use the same mod set, `Use Original` keeps the exported sprite name and is usually the right default. Sprite conflicts can also be replaced by typing a replacement sprite name, or skipped if the object should not be rebuilt.

Object conflicts can currently be reviewed or skipped. Automatic object replacement is intentionally not attempted. Incomplete legacy door data is reported separately so old exports with missing closed-door sprite state are visible before import.

Dry Run progress shows package tiles checked by the server while the client uploads the package.

## Safety

Importing is destructive inside the exported footprint. Existing objects in the target area are replaced by the export data.

Always back up the target save before importing. Test every migration on a local or disposable server before using it on a live server. Do not import while players are active in the target footprint.

Server-side command handling requires admin access. Package transfer parts are
bounded client-side and server-side to reduce accidental misuse.

## Current Limitations

- Vehicles are not migrated.
- Zombies are not migrated.
- Player inventories are not migrated.
- Some special object state, such as generator fuel/condition and mannequin setup, still needs manual verification after import.
- Large radius exports/imports can take time and may briefly stall the game/server while individual tiles are processed.

## Memory Notes For Large Exports

Export, Dry Run and Import use the package format to avoid one giant JSON string.
Export writes tile JSON lines directly to disk on the admin PC through small raw
transfer parts. Dry Run streams those lines back to the server and scans one
tile at a time.

Import uploads the full package into a temporary server-side tile file first. Only
after that upload succeeds does the server clear the target footprint and rebuild
tiles over later ticks. This keeps heap pressure low and avoids clearing the map
after a failed upload.

During clearing, linked vanilla door groups are removed as a unit. Double-door
and garage-door tiles can span adjacent squares; removing only the currently
visited square can leave orphaned pieces behind.

Live multiplayer door sync is intentionally conservative. Newly rebuilt doors
are transmitted as complete objects, but Area Export does not send generic
`syncIsoObject` packets for them because B42 can reject the rebuilt live object
index even though the same door persists and works after chunk reload. Garage
door parts are restored as a closed linked sprite group and are not toggled
piece-by-piece during import.

Import progress is phase-based: client upload, target footprint clearing, then
server tile rebuild. The progress bar resets for each phase because each phase
has its own measurable total.

Very large areas can still take time. Individual tiles with many objects or items
can briefly stall while decoded and rebuilt. Legacy single-file JSON exports above
the safety limit are refused by the UI; re-export them with the current package
format.

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

Area Export is open source:

https://github.com/Elfwyn/ProjectZomboid-AreaExport/

You may use the public code for your own mods, forks, variants, or compatibility patches. Reuse and adaptation are explicitly allowed and encouraged.
