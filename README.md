# Kool Save Editor for Macintosh

A native macOS (SwiftUI) savegame editor for *Star Wars: Knights of the Old Republic* and
*The Sith Lords*, named in honor of the Windows [KotOR Savegame Editor (KSE)][kse]. It covers
everything KSE does, with the BioWare file formats implemented in Swift from
[xoreos-tools][xoreos]. Nothing from xoreos or KSE is needed at runtime.

## Features

- Finds saves automatically in the Mac App Store and Steam locations of both games, including
  TSL Steam Cloud saves; other folders can be added.
- Savegame name, time played, cheat flag.
- Player and companions: name, gender, appearance, portrait (with previews), soundset,
  attributes, skills, experience, alignment, hit/Force points, Min 1 HP, feats, Force powers,
  classes (change, add, remove, level), equipment (equip from the game's item blueprints,
  unequip to the inventory).
- Party: credits, party XP, TSL components and chemicals, the active party, and TSL influence
  for every companion.
- Inventory: change quantities, remove, add any item blueprint (game or override folder),
  copy and paste an inventory between saves.
- Journal: change quest states, add and remove quests.
- Global variables: booleans, numbers and strings.
- Undo/redo for every edit; Xbox `.sig` files are regenerated when present.

### Versions and rollback

Before anything is written, the save folder is copied to
`~/Library/Application Support/KSEMac/Versions` (APFS clones, so copies are nearly free).
Files are then replaced atomically, read back and re-parsed. If a write or the verification
fails, the save is rolled back to that copy automatically. The Versions section lists every
copy and restores any of them (restoring first saves the current state as another version).
Saves changed on disk since they were opened (for example by the game) are detected before
writing.

## Game data

Names, icons, and the lists of feats, powers, classes, items and quests come from the game
installation (`chitin.key`, `dialog.tlk`, the override folder and the GUI texture pack). The
app looks in the Steam libraries and `/Applications`; otherwise choose the folder in
**Settings › Games** (for the Mac versions it is inside the app bundle, e.g.
`Contents/Assets` or `Contents/GameData`). Saves can still be edited without it, with numbers
shown instead of names.

macOS asks for permission the first time the app reads the Mac App Store containers
(“access data from other apps”).

## Building

Requires Xcode 16 or newer; runs on macOS 14 Sonoma or newer.

```sh
Tools/install-app.sh                       # build a universal Release app into /Applications
open KSEMac.xcodeproj                      # or build and run the KSEMac scheme in Xcode
cd KotORKit && swift test                  # library tests
Tools/release.sh                           # signed, notarized DMG in build/ (maintainers)
```

Layout:

- `KotORKit/Sources/Aurora` – GFF, ERF, KEY/BIF, 2DA, TLK, TPC/TGA and code pages (from xoreos-tools).
- `KotORKit/Sources/KotORSave` – save loading and editing, game data, discovery, versions and safe writing (from KSE).
- `KSEMac` – the SwiftUI app.
- `Tools/make-icon.swift` – renders the app icon.

## License and disclaimer

The full text is in [`NOTICE`](NOTICE); the license is in [`LICENSE`](LICENSE).

- **Derived from GPL software.** Named in honor of KSE, this program is a Swift translation
  of parts of [KSE][kse] (© tk102, FairStrides and the KSE Team) and [xoreos-tools][xoreos] (the legal
  property of its developers), both licensed under the GNU GPL version 3 or later. As those
  licenses require, this program as a whole is distributed under the same terms.
- **No copyright claimed.** Most of the new code was written by an AI model. The maintainer
  claims no copyright in this program; copyright in the parts derived from KSE and
  xoreos-tools remains with their authors.
- **No warranty, no liability.** This program is provided "as is", without warranty of any
  kind. The maintainer accepts no liability for any damage or loss arising from its use,
  including damaged or lost saved games. Use it at your own risk.
- **Not affiliated.** Star Wars, Knights of the Old Republic and KotOR are trademarks of
  Lucasfilm Ltd. This program is not made, endorsed or supported by Lucasfilm, Disney,
  BioWare, Obsidian Entertainment, Aspyr Media, the KSE team or the xoreos project, and
  contains no game files.

[kse]: https://gitlab.com/kotorsge-team/kse
[xoreos]: https://github.com/xoreos/xoreos-tools
