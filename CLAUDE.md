# Kennel

Shared WoW Forever rules: ../CLAUDE.md (if present locally).

Hunter bar with three icons: pet (call / revive / feed), pet food, ammo, plus
auto-buy ammo at vendors and an options window. Released (no longer Beta).

## Files
- `Kennel.toc`, `Kennel.lua` (~1,500 lines, all logic and the options window),
  `Bindings.xml` (`CLICK KennelPet:LeftButton` / `RightButton`).
- `Kennel-summary.md` — design notes, Forever findings, open assumptions and a
  per-version change log. **Read it before touching pet-button, food or ammo
  logic**, and add a `Changes` entry for every version. (Its top "never loaded
  in game" status line is out of date; the change log has in-game reports.)

## SavedVariables `KennelDB`
- From `defaults`: food, lowAmmo (200), lowFood (5), autoBuyAmmo, ammoTarget
  (1000), skipBuffFood (true), locked, shown, scale, point/x/y.
- Also: `petDead`, `lastPet`, `refused[family]`, `tooLow`.

## Behaviour to keep
- Call / revive / feed on the pet button works in game. Forever's spellbook
  shows "Call <pet name>"; summoning is Call Pet 1–5 (IDs 883, 83242–83245).
  If a change to the pet button breaks it, add diagnostics to
  `/kennel spells` / `/kennel clicks` and ask me to test rather than guessing.
- Pet button is a secure button driven by a state driver; never change its
  attributes in combat (queue for PLAYER_REGEN_ENABLED via `ApplyMacros`).
- Setup steps run through `Try()` so one failure prints once instead of
  breaking the addon.
- Food: lowest item level first; learn from refusals; skip "Well Fed" buff
  foods (tooltip scan) unless `skipBuffFood` is off. Ammo: bags + quiver,
  matching weapon type; auto-buy never exceeds money or bag space.
- Not wanted: an Auto Shot bar.

## Slash: `/kennel`, `/kn` — opens options; help, food, buy, lock/unlock,
spells, clicks, debug, show/hide, scale, reset.
