## What this changes

<!-- What does it do, and why? Link an issue if there is one. -->

<!-- Title: a Conventional Commit, e.g. "fix(craft): wrong cost for crafted parts" or "feat: leatherworking".
     It becomes the commit on main and decides the next version (see CONTRIBUTING.md). -->

## How it was tested

- [ ] `lua tests/run.lua` passes (the Checks workflow runs it too)
- [ ] Added or updated a test, if this changes logic in Core.lua, Craft.lua or Live.lua
- [ ] Tried in game. What I checked:
  <!-- e.g. Crafting tab, Blacksmithing, No anvil on, hovered Copper Chain Belt -->

## Checklist

- [ ] Ledger is still read-only: nothing buys, sells, posts, cancels or mails
- [ ] No SavedVariables, character names, gold or other personal data in the code, tests or screenshots
- [ ] README updated if a command, button or column changed
