# Polestar Plus: the fork

Polestar Plus is a fork of [Polestar](https://github.com/fitzforge/polestar), the leveling guide addon
for World of Warcraft: Forever. It keeps Polestar's licence: the GNU General Public License version 3
([LICENSE](LICENSE)) with Polestar's additional permissions ([LICENSE-EXCEPTION.md](LICENSE-EXCEPTION.md)),
Polestar's copyright notices, and the third-party material with its own licences and credits
([THIRD_PARTY.md](THIRD_PARTY.md), the `CREDITS.md` and `LICENSE-DATA.txt` files in the addon folders).

What it adds:

| Feature | Where | How to open it |
|---|---|---|
| **Route my whole log**: one guide that finishes and hands in every quest in the quest log | `addon/Polestar/Fork/LogRoute.lua` | the button under *Guide me* in the quest-log window (*Clean up quest log* in the guide menu), or `/psf emptylog` |
| **Zone completionist**: one guide for every quest of a zone the character can do | `addon/Polestar/Fork/ZoneQuests.lua`, `Fork/ZonePicker.lua` | the *Zone quests* button in the same window, `/psf zone` (the zone list) or `/psf zone <name>` |
| The route maths both share | `addon/Polestar/Fork/RouteKit.lua` | |

## Side by side with Polestar

The fork is renamed when it is built, so both addons load in one game with nothing shared:

| What | Polestar | Polestar Plus |
|---|---|---|
| Folders and TOCs | `Polestar`, `Polestar_Guides`, `Polestar_Nav_*`, ... | `PolestarPlus`, `PolestarPlus_Guides`, `PolestarPlus_Nav_*`, ... |
| AddOns list | Polestar | Polestar Plus (in orange), category *Polestar Plus* |
| Global table | `Polestar` | `PolestarPlus` |
| Saved settings | `PolestarDB`, `PolestarCharDB` | `PolestarPlusDB`, `PolestarPlusCharDB` (fresh settings) |
| Slash commands | `/polestar`, `/pole`, `/ps` | `/psf`, `/polestarplus`, `/psplus` |
| Frames, templates, key bindings, popups, bag widget ids, addon-message prefixes | `Polestar...`, `POLESTAR_...`, `polestar_...` | `PolestarPlus...`, `POLESTARPLUS_...`, `polestarplus_...` |
| Text and chat | "Polestar" | "Polestar Plus" (its chat prefix in orange) |

`/rl`, `/way` and the TomTom stand-in are taken by whichever addon finds them free first (Polestar,
which loads first). The fork leaves out the Recorder (its own download, which records for Polestar)
and Freedoom Arcade (Polestar's copy already provides it).

## Building

The source in this repository is Polestar's tree with the fork's features added; it is not renamed.
The rename is a build step, `tools/lib/fork/rebrand.js`, run by `node tools/polestar.js fork`:

```sh
gh release download v0.4.2 -R fitzforge/polestar -p 'Polestar-0.4.2.zip' -D dist/fork   # the generated data git lacks
node tools/polestar.js fork build --data dist/fork/Polestar-0.4.2.zip                   # -> dist/fork/AddOns/PolestarPlus*
node tools/polestar.js fork check --against "/Applications/World of Warcraft/_forever_/Interface/AddOns"
node tools/polestar.js fork install --to "/Applications/World of Warcraft/_forever_/Interface/AddOns"
```

- `build` takes every `addon/Polestar*` folder (the files git tracks or would add), plus
  `Polestar_QuestDB` and `Polestar_Codex` from `--data` (an upstream release zip of the same version:
  those two are generated from local reference data and are not in git), and writes the renamed copies.
- `check` fails on a Polestar name left in the built code (comments may still say Polestar) and, with
  `--against`, on any folder, SavedVariable, slash command, binding, frame, popup, addon-message prefix
  or global (read with `luajit -bl` when LuaJIT is installed) that both installs claim.
- `install` replaces only the `PolestarPlus*` folders. It never touches Polestar's. A new addon needs a
  full game restart, not `/reload`.

The rename rules (in `rebrand.js`'s header): `Polestar...` → `PolestarPlus...` wherever it is not inside
another word (code, comments, strings, TOCs, XML), `POLESTAR` → `POLESTARPLUS`, `polestar_` →
`polestarplus_`, the `/polestar` slash command → `/psf`, and, inside Lua strings that hold a space and in
TOC titles, "PolestarPlus" read as a word → "Polestar Plus". Lowercase values (the `polestar` skin key,
polestar.guide, the GitHub and Discord links) stay. Because they are rules, not edits, nothing has to be
redone after a merge.

## Keeping up with Polestar

```sh
git fetch upstream
git merge upstream/next            # Polestar's branch for new work; releases are tagged v<version>
cd rust && cargo test --release -p forge-addontest --test addontest fork_routes && cd ..
node --test tests/fork.test.js
gh release download v<version> -R fitzforge/polestar -p 'Polestar-<version>.zip' -D dist/fork
node tools/polestar.js fork build --data dist/fork/Polestar-<version>.zip && node tools/polestar.js fork check --against dist/fork/release
```

The fork changes only a few lines of Polestar's own files, each marked `Fork:` or `Polestar Plus`:
`addon/Polestar/Polestar.toc` (loads `Fork\Fork.xml`), `addon/Polestar/UI/QuestRoom.lua` (the two
buttons and the `logroute` list) and `addon/Polestar/Core/Init.lua` (`/rl` only when free). A merge
conflict is most likely there.

## The two guides

**Route my whole log** (Lookup planner `questlog`, guide `lookup/questlog/all`). Every quest in the log
goes in: an unfinished one as its objectives (kill, collect, use, talk and interact goals at their spawn
areas, from the Codex, as Polestar's own quest lookups place them), each before its turn-in; a finished
one as its turn-in. Quests handed in to the same NPC or object share one stop. The route starts where you
stand and is ordered over the travel planner's costs (flights, boats, portals between zones, a straight
run inside one): small routes by Polestar's own stop planner (`Dungeons.PlanStops`), big ones by
nearest-next among the stops whose work is done, then Or-opt and 2-opt moves that never put a turn-in
before its quest's objectives. What it cannot route is listed with the reason, never dropped: no quest
data, no known place for its work or its turn-in, inside a dungeon or raid, an elite you are not 5 levels
above, and grey unfinished quests (with an Abandon button, as the quest-log window has).

**Zone completionist** (Lookup planner `zone`, guide `lookup/zone/<map>`). Pick a zone from the list or
by name. The guide takes every quest of that zone your character can do: each pick-up, objectives and
turn-in, every accept after the turn-ins of its prerequisites (all of `pre`, one of `preAny`), a
breadcrumb before the quest it leads to, one of two exclusive quests, and the quest log's room kept.
A prerequisite in another zone comes into the route, its steps marked *Outside <zone>*. Left out, each
with its reason in the zone's detail: quests already done (the client's completed quests, counted in
"X of Y done"), a level you don't have yet, a profession, closed by a quest you took, inside a dungeon
or raid, an elite, a start item you don't have, or a prerequisite you can't do. Quests of the other
faction, race or class, and holiday quests, are not counted.

## Tests

- `rust/crates/forge-addontest/tests/addontest/fork-routes.rs`: both guides built from a synthetic Codex
  in the real addon and played to the end by the guide simulator; objectives before turn-ins, accepts
  after their prerequisites and breadcrumbs, the shared ender stop, every left-out reason, the zone list
  and its detail, the slash commands, an 80-quest zone, and random stop sets (dependencies always kept,
  2-opt never longer).
- `tests/fork.test.js`: the rename rules, a full build with no leftover names, and Polestar and the
  built Polestar Plus loaded together in one stub client with distinct tables, slash commands and
  SavedVariables.

## Upstream

Nothing here has been offered to Polestar. The features answer Polestar's open issues #2701 (a
quest-log mode) and #3230 (the hand-in guide skips quests a route hands in); a pull request upstream is
the maintainers' call and the fork owner's, never automatic.
