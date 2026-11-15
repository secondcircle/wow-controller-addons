# WoW controller addons

Two small addons for playing a healer (or anyone who targets party members a lot) on a controller.
Built and used on **WoW Forever** (interface 16001) with the built-in gamepad action bars.

| Addon | What it does |
|---|---|
| **Party Diamond** | Moves Blizzard's own party frames into a diamond that matches the face buttons: top = Y, right = B, bottom = A, left = X. You see who a button will pick without reading a list. |
| **SoftTarget** | FFXIV-style soft targeting. LB + party button marks an ally (gold border) instead of targeting them. Your next helpful spell goes to that ally and your enemy target never changes. |

They work on their own or together.

## Install

1. Download the zip from the [latest release](https://github.com/secondcircle/wow-controller-addons/releases/latest).
2. Unzip it into your AddOns folder, for example
   `C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\`
   so that you end up with `AddOns\PartyDiamond\` and `AddOns\SoftTarget\`.
3. Type `/reload` in game (or restart the game).

## Update

Download the newest zip from the same link and unzip it over the old folders. Your settings are kept.

If you use git, you can instead clone this repository and copy (or link) the two folders into
`AddOns`, then `git pull` to update.

## Settings

Both addons have a page under **Options > AddOns**, and every setting also has a slash command.

### Party Diamond: `/pdiamond`

| Command | What it does |
|---|---|
| `/pdiamond` | Shows what was found and who goes where |
| `/pdiamond config` | Opens the options page |
| `/pdiamond help` | Lists every setting with its current value |
| `/pdiamond move` | Shows a box to drag the diamond; run again to lock |
| `/pdiamond reset` | Puts the diamond back in its default place |

| Setting | Default | Meaning |
|---|---|---|
| `enabled on\|off` | on | Whole addon on or off (`/reload` after turning off restores Blizzard's layout) |
| `scale 0.5-3` | 1.2 | Size of the party frames |
| `width 0\|30-250` | 0 | Frame width; 0 = Blizzard's width (raid-style party frames only) |
| `height 0\|15-150` | 0 | Frame height; 0 = Blizzard's height (raid-style party frames only) |
| `gap 0-60` | 4 | Space between frames |
| `freeze on\|off` | on | Keep the layout during combat |
| `hideextras on\|off` | on | Hide the "Party" title and other leftovers |
| `slot1` ... `slot4` `auto\|up\|right\|down\|left` | auto | Where each party member goes. Auto reads your "Target Party Member" key bindings |
| `hiderole on\|off` | on | Hide role icons |
| `hideaggro on\|off` | on | Hide the red threat border |
| `firstname on\|off` | on | Show first names only |
| `centernames on\|off` | on | Centre the names |
| `namescale 0.4-1.5` | 0.65 | Name text size (1 = Blizzard's size) |

With raid-style party frames you are in the centre of the diamond. With the standard party frames only the four party members are arranged.

### SoftTarget: `/soft`

| Command | What it does |
|---|---|
| `/soft` | Status: on/off, how many buttons were hooked, current soft target |
| `/soft config` | Opens the options page |
| `/soft help` | Lists every setting with its current value |
| `/soft on` / `/soft off` | Turns soft targeting on or off |

| Setting | Default | Meaning |
|---|---|---|
| `sticky on\|off` | on | On: the soft target stays until you pick someone else. Off: it is used up by the next helpful spell |
| `again target\|clear\|keep` | target | What LB + the same ally a second time does: target them for real, clear the soft target, or nothing |
| `friendwins on\|off` | on | While your real target is friendly, helpful spells go to them instead of the soft target |
| `self on\|off` | on | LB + yourself is a soft pick (off = normal targeting) |
| `pet on\|off` | on | LB + your pet is a soft pick (off = normal targeting) |
| `items on\|off` | on | Helpful items on the action bar (bandages) use the soft target |
| `macros on\|off` | on | Macros on the action bar: `/cast` and `/use` lines with a helpful spell or item go to the soft target |
| `color rrggbb` | ffd100 | Soft target border colour |
| `size 1-10` | 3 | Soft target border thickness |
| `label on\|off` | on | Show "Soft: name" on screen when the ally has no frame to put a border on |
| `targetborder on\|off` | off | Show Blizzard's own border on your real target's party frame |

## Good to know

- **Combat:** the game does not let addons move party frames or change secure settings in combat. Changes you make in combat apply when the fight ends.
- **SoftTarget affects spells, items and macros on the gamepad action bars.** In a macro, `/cast` and `/use` lines with a helpful spell or item are sent to the soft target; lines that already have `[conditions]`, and `/castsequence`, are left as written. Assist (target of target) and the raid marker button are left alone.
- **SoftTarget's soft target is used at the press**, not when the cast lands. With sticky off, a press that fails (out of range, no mana) still uses it up. That is a limit of what the game allows.
- If you ever see an "action blocked" message, turn these addons off first to check whether they are the cause, and please open an issue.

## Status

These were written for one setup and are young. SoftTarget's core (heals going to the soft target) and the diamond layout are used in game daily; the options pages and several of the newer settings have only been tested outside the game so far. Bug reports are welcome under Issues.
