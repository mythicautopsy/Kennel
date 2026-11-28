# Kennel – Hunter pet, food and ammo bar (WoW Forever)

A small three-icon bar for Hunters on **WoW: Forever**: one button for your pet, your pet's food, and your ammo. It stays out of the way and turns red when something needs attention.

## Features

**Pet button**
- Left click does the right thing for the moment: **call** your pet if it's not out, **revive** it if it's dead, **feed** it when it's alive (out of combat).
- Right click always revives.
- Remembers when your pet died, even after its body disappears, so left click revives instead of failing to call.
- Finds your pet spells in your spellbook, including Forever's renamed ones ("Call <your pet's name>").
- Icon tint shows your pet's happiness.
- Key bindings for both clicks under Esc > Key Bindings > Kennel.

**Pet food**
- Picks food from your bags automatically, matching your pet's diet.
- Uses your lowest-level food first, to save your better food.
- Learns from refusals: if your pet won't eat something, Kennel skips it from then on.
- Leaves food that gives a "Well Fed" buff for you (can be turned off in the options).
- Shows the food icon and how many you have; the tooltip lists every food your pet eats.
- Or set a food yourself.

**Ammo**
- Counts all arrows or bullets in your bags, quiver and ammo pouch for the weapon you have equipped.
- Turns red when you run low, or when your ammo doesn't fit your weapon (arrows with a gun).
- **Auto-buy:** at a vendor, buys the highest-level ammo you can use, up to the amount you set. Never spends more than you have or buys more than fits in your bags.

**Options window**
Type `/kennel` (or right-click the bar's drag handle) to change everything: show/lock/size the bar, food mode, warning levels, auto-buy amount.

## Commands

| Command | What it does |
|---|---|
| `/kennel` or `/kn` | Open the options window |
| `/kennel help` | List all commands |
| `/kennel food auto` | Pick food automatically (default) |
| `/kennel food <item name>` | Always use this food |
| `/kennel buy <number>` / `on` / `off` | Auto-buy ammo up to this amount |
| `/kennel lock` / `unlock` | Hide or show the drag handle |
| `/kennel spells` | Check the pet spells were found |
| `/kennel debug` | Print details for bug reports |

## Install

1. Put the `Kennel` folder in `World of Warcraft\_classic_beta_\Interface\AddOns`.
2. **Fully quit and restart the game.** Forever doesn't load new addon code on `/reload`.
3. If it shows as out of date, tick "Load out of date AddOns".

## Known issues

- Food kinds are guessed from item names; unusual food names may be missed. Set those with `/kennel food <name>`.

Bug reports are welcome. Please include the output of `/kennel debug`.

## Author

mythicautopsy – The Monsoon Brigade @ Alliance PVE

Licence: MIT
