# Kennel: project summary (v2.11.0, formerly HunterPetBar)

A small WoW Forever addon for Hunters. **Status: released (no longer Beta).** Loaded and tested in game; Call Pet from the pet button confirmed working in 2.11.0.

## What it does
- **One pet button** (secure button, `SecureActionButtonTemplate`)
  - Left click: pet dead -> `Revive Pet`; no pet -> `Call Pet`; pet alive and out of combat -> `Feed Pet` then `/use <food>`
  - Right click: `Revive Pet`
  - Icon changes with state: Call Pet / Revive Pet (red tint if dead) / Feed Pet (tinted yellow or red by happiness)
- **Ammo icon** next to it
  - Shows equipped ammo icon and a count of equipped + bag stacks (`GetItemCount`)
  - Count turns red at or below `lowAmmo` (default 200)
  - Icon follows the ranged weapon: bow/crossbow -> arrow icon, gun -> bullet icon (greyed with red 0 if nothing is equipped)
  - Wrong ammo for the weapon (e.g. arrows with a gun) turns red and the tooltip says so
- Movable bar with a drag handle; position and settings saved in `KennelDB`

## Slash commands (`/kennel`, short `/kn`)
`food` (show), `food auto` (default), `food <exact item name>` (manual override), `food forget`, `ammo <number>`, `spells` (checks the pet spell names were found), `clicks` (echoes each click to chat), `debug` (prints client, slot and API details), `lock` / `unlock`, `show` / `hide`, `scale <0.5-2>`, `reset` (food kept)

## Key bindings
Esc > Key Bindings > Kennel: left click and right click of the pet button (`CLICK KennelPet:LeftButton` / `RightButton`).

## Files
- `Kennel.toc` - `## Interface: 16001`, SavedVariables `KennelDB`
- `Kennel.lua` - all logic
- `Bindings.xml` - two click bindings

## Forever-specific notes found so far
- WoW Forever beta uses interface **16001** (other Forever addons list it; "Camelot" game type, so a `_Camelot.toc` suffix also exists). If the addon shows out of date, enable "Load out of date AddOns".
- Ammo exists in Forever; ammo slot is inventory slot 0, ranged weapon is slot 18.
- Pets scale with the hunter's gear; every pet has the Feed Pet / loyalty / happiness loop.
- Game blocks changes to secure buttons in combat. Macro text and layout are queued and applied on `PLAYER_REGEN_ENABLED`.
- You cannot tame a new beast while you already have an active pet.

## Open assumptions to verify in game
1. Spell names `Call Pet`, `Revive Pet`, `Feed Pet`, `Mend Pet` match Forever's names (icons show a question mark if a name is wrong). **Likely wrong for Call Pet:** Huntwell Forever's CurseForge page says Forever renames Call Pet to "Call <pet's name>". Fixed in 2.3.0: the summon spell is now found in the spellbook. Still unverified in game.
2. A dead pet may count as "no pet" for the `[nopet]` macro condition, so left click could try `Call Pet`. Right click (Revive) is the fallback.
3. `GetPetHappiness` and `GetItemInfoInstant` exist and behave like Classic.
4. `RegisterForClicks` uses `AnyDown` or `AnyUp` depending on the `ActionButtonUseKeyDown` cvar.

## Ideas from HunterStrip (CurseForge), not built yet
- Use `Mend Pet` on left click when in combat
- Show how many feedings of the chosen food are left in bags
- Low food / low ammo / hungry-pet alert (optional sound)
- Happiness shown as a border colour
- Option to fade or hide the bar out of combat
- Per-food rules (Auto / Always / Never)
- Explicitly NOT wanted: an Auto Shot bar

## Publishing (CurseForge)
- Author: mythicautopsy - The Monsoon Brigade @ Alliance PVE (in toc `## Author`, README, LICENSE).
- Naming convention (all addons): plain name for folder/toc/title; listing name `<Name> – <what it does> (WoW Forever)`; upload file `<Name>-<version>-forever.zip`.
- Package includes README.md (also the CurseForge description) and MIT LICENSE; logo `Kennel-logo-400.png` (original design, 400x400).
- Released as a full release (no longer Beta) now that Call Pet works.

## Changes
- 2.12.0: user asked for feeding to leave buff food alone. Auto food now reads each candidate's bag tooltip (`C_TooltipInfo.GetBagItem`, else a hidden `KennelScanTip`) and skips items whose tooltip contains "well fed"; result cached per item ID; an empty tooltip is retried up to 3 times, then treated as plain food. New setting `skipBuffFood` (default on), checkbox in the options window's Pet food section (later controls moved down 26px, window 586px tall). Food icon tooltip lists buff foods kept back. Manual `/kennel food <name>` is not filtered.
- 2.11.0: user reports call still not working in 2.10. Research: Forever runs the retail-style engine, where summoning is Call Pet 1-5 (IDs 883, 83242-83245, one per stable slot) and retail macros use `/cast [nopet] Call Pet 1`. Likely bug: the spellbook "Call Neko" entry is a display name or a flyout, and 2.10 used `info.spellID or info.actionID`, which for a flyout is the flyout number. Now: flyout entries are skipped (spellID only); call uses the known Call Pet slot spell whose shown name matches the last pet, else the first known slot; revive/feed prefer standard IDs 982/6991 when known. `/kennel spells` lists known call slots and what left/right click will cast. Test status (from user): Call Pet from the pet button now works in game.
- 2.10.0: click test from user showed clicks arrive and the macro runs `/cast ... [nopet] Call Neko` but nothing is cast: on Forever the shown name "Call <pet>" can't be cast by name. Left click is no longer one macro: a secure state driver (`[@pet,dead] dead; [nopet] nopet; alive`, SecureHandlerStateTemplate) sets `type1=spell` with the spell ID for Call/Revive (Revive also when `petDead` is known), and `type1=macro` for Feed + food. IDs come from the spellbook entry, else Classic IDs 883/982 if known. Clicks registered on one edge only (key down or up, per `ActionButtonUseKeyDown`), since both fired before. Click echo shows `cast spell <id>`.
- 2.9.0: auto-buy ammo on MERCHANT_SHOW (on by default, `autoBuyAmmo`, target `ammoTarget` default 1000). Picks merchant ammo matching the weapon (arrow for bow/crossbow, bullet for gun) that is purchasable/usable with required level <= player level: highest required level, then item level, then cheapest. Buys ceil((target - all ammo of that kind in bags) / bundle) purchases, capped by stock, money and free bag slots, one `BuyMerchantItem(index)` every 0.3s; stops if the vendor closes; prints what it bought and the cost. Options window: checkbox + 'Top up to' slider 200-4000. Slash: `/kennel buy <n>|on|off`.
- Test status (from user): summon spell is "Call <pet's name>" and `/kennel spells` reports it OK, so name lookup works; left-click Call still fails, cause unknown until the click test is done.
- 2.8.0: options window (`KennelOptions`), opened by `/kennel` (commands list moved to `/kennel help`) or right-clicking the drag handle; Esc closes it; draggable. Sections: Bar (show, lock, size slider 0.5-2, reset position), Pet food (auto vs always-use with text box, live summary of next feed, food-red-at slider 0-40, forget refused foods), Ammo (ammo-red-at slider 0-1000), Troubleshooting (show clicks, check pet spells). Also registered in the game's Options > AddOns (Settings API, or InterfaceOptions on older clients) with a button that opens the window. Built from long-standing templates only (UICheckButtonTemplate, UIPanelButtonTemplate, InputBoxTemplate, UIPanelCloseButton); sliders hand-built. New setting `lowFood` (default 5).
- 2.7.0: user reports revive does nothing on left or right click, while the tooltip correctly says the pet is dead (so new code is loaded and state logic works). Suspect spell name mismatch. Pet spells now also resolved by Classic spell ID (Call 883, Revive 982, Feed 6991): spellbook entry by name, by ID, by prefix, then ID if `IsPlayerSpell`/`IsSpellKnown`, with the display name from `C_Spell.GetSpellName(id)`. Right click casts by spell ID when known. `/kennel spells` prints name, ID, how it was found, and what the Classic ID resolves to. `/kennel clicks` now also prints when the button receives the click (PreClick), to separate "click never arrives" from "cast fails".
- 2.6.1: reviewed call/revive. Gap fixed: after a pet dies and its body despawns (time, zoning, relog) the game reports no pet, so left click used to try Call and fail. Kennel now keeps `KennelDB.petDead` (set when the pet is seen dead, cleared when seen alive) and the `[nopet]` branch casts Revive while it's set; icon shows Revive in red. Self-correcting: a "pet is dead" error after a Call click sets the flag; a "not dead" error after a Revive click clears it. Tooltip names the exact spell each click casts. Decision table: alive out of combat -> Feed; alive in combat -> nothing; dead (body or not) -> Revive; dismissed -> Call. Right click always Revive.
- 2.6.0: third icon for pet food, between pet button and ammo (layout: pet | food | ammo). Shows the food the next feed uses (auto pick or manual) with bag count, red at 5 or less, greyed when none. Tooltip: item tooltip, whether it's auto/manual, and every eligible food in bags with counts (chosen one in green). Auto pick keeps the last choice while no pet is out.
- 2.5.1: user reports revive click does nothing (call pet also didn't work). Revive and Feed names now looked up in the spellbook like Call (`<Word> Pet`, `<Word> <pet name>`, then any `<Word> ...`). Right click now `type2=spell` with the found revive name instead of a macro. `RegisterForClicks("AnyUp","AnyDown")` in case clicks never reached the secure handler. `/kennel clicks` prints what each click runs, to tell "click not firing" from "spell name wrong".
- 2.5.0: pet food picked automatically. Bags scanned for Food & Drink (class 0) or cooking items (class 7) whose name matches a diet word list (meat/fish/bread/cheese/fruit/fungus), filtered by `GetPetFoodTypes()` when the client has it. Lowest item level first, then biggest stack; macro uses `/use item:<id>`. If the pet refuses (UI_ERROR_MESSAGE within 5s of a click, `SPELL_FAILED_WRONG_PET_FOOD` / `SPELL_FAILED_FOOD_LOWLEVEL` or text containing "food"), the item is remembered in `KennelDB.refused[family]` / `KennelDB.tooLow` and another is picked. Manual `/kennel food <name>` still overrides. Known limit: name-based guessing can miss or misfile foods; buff foods are not excluded.
- 2.4.1: user reports no pet-button icon when no pet is out. Icon now tries, in order: the spell's icon by name, the summon spell's icon read from the spellbook entry, then a fixed icon (BeastCall / BeastSoothe / BeastTraining). `SetIcon()` checks the texture actually took before moving on. `/kennel debug` shows which icon was used.
- 2.4.0: user reports arrows not detected. Ammo now found by scanning bags (bags 0..NUM_BAG_SLOTS, quiver/pouch included, `C_Container` or old API) for projectile items (class 6: arrow 2, bullet 3). Count = all ammo of the kind your weapon fires; icon = ammo-slot item, else your biggest stack of that kind. Tooltip lists every ammo stack and notes when the ammo slot reads empty. `/kennel debug` adds a bag ammo summary.
- 2.3.1: first in-game report: no icons shown and loaded ammo not shown. Added: every setup/update step runs through `Try()` and prints its error in chat once; bar gets a position immediately; item functions use `C_Item` when present (GetItemInfoInstant/GetItemCount/icons); ammo read by item ID as well as link; ammo/ranged slot numbers asked from `GetInventorySlotInfo`; `/kennel debug`. Cause not yet known.
- 2.3.0: summon spell found in the spellbook instead of the fixed name `Call Pet`. Order: exact "Call Pet", then "Call <last pet's name>" (name saved in `KennelDB.lastPet`), then any spell starting "Call " (not "Call of"). Re-checked on `SPELLS_CHANGED` and when the pet changes. Tooltip shows the summon spell in use. New `/kennel spells` command.
- 2.2.0: renamed HunterPetBar -> Kennel (folder, toc, SavedVariables `KennelDB`, frames, bindings, `/kennel` + `/kn`). Name checked on CurseForge: "Quiver" was taken, "Kennel" looked free.
- 2.1.1: `/hpb` on a non-Hunter no longer errors; events registered with pcall so a missing event can't break loading; left click revives a dead pet first and never feeds a dead pet; dragged position no longer fought by the layout cache; ammo count passed as text.
- Only a rough bracket/block balance check was possible (no Lua interpreter, no network for installs).

## Install
Put the `Kennel` folder in the WoW Forever `Interface\AddOns` folder (`_classic_beta_`), then **fully quit and restart the game**. Forever does not load new addon code on `/reload` (per Huntwell Forever's CurseForge page).
