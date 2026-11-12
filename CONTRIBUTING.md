# Contributing to Ledger

Thanks for helping. Pull requests are welcome from anyone: you don't need access to this repo.

## The one hard rule

Ledger is **read-only**. It never buys, sells, posts, cancels or mails anything, and never clicks anything on
your behalf. It only reads (mail invoices, bags, AH searches you start) and shows. Changes that automate
auction house or other gameplay actions won't be merged. They'd also break Blizzard's add-on policy.

## How to contribute

1. Fork the repo and create a branch (`git checkout -b blacksmithing-fix`).
2. Make your change. Keep to the existing style: plain Lua 5.1, no libraries, money in copper.
3. Run the tests (below) and add one if you changed logic in `Core.lua`, `Craft.lua` or `Live.lua`.
4. Try it in game (below).
5. Open a pull request against `main` and fill in the checklist.

Every pull request runs the **Test** workflow automatically. It has to pass before the PR can be merged. A
maintainer reviews it, merges it, and includes it in the next release.

## Tests

The tests run Ledger outside the game, with stand-ins for the WoW API and made-up prices and recipes
(`tests/wow.lua`). They need Lua 5.1 (what the game uses; 5.3/5.4 also work):

```
lua tests/run.lua
```

Run this from the add-on folder. Add tests to `tests/test_portfolio.lua` or `tests/test_craft.lua`, or make a
new `tests/test_*.lua` file and add it to `FILES` in `tests/run.lua`. `UI.lua` isn't loaded by the tests (it's
all frames); CI only syntax-checks it, so UI changes need checking in game.

**Never commit your own SavedVariables** (`WTF\...\Ledger.lua`) or anything from them, such as character
names, gold, trades or loans. The repo is public. Test data must be made up.

## Trying a change in game

Each pull request's **Test** run also builds an installable zip, packaged exactly like a release:

1. Open the pull request's **Checks** tab, then the **Test** run.
2. Under **Artifacts**, download the `Ledger-<version>-forever.zip` (you need to be signed in to GitHub).
3. Delete your `Interface\AddOns\Ledger` folder, unzip the download into `Interface\AddOns\`, and `/reload`.
4. Check what the PR changed, plus a quick look at each tab. The numbered **Test steps** in the README cover
   most features.

Back up your `WTF\Account\<account>\SavedVariables\Ledger.lua` first if you care about your history: a buggy
build can write bad data into it.

## Releases (maintainer)

1. Bump `## Version:` in `Ledger.toc` and push to `main`.
2. Tag it and push the tag: `git tag v0.9.2 && git push origin v0.9.2`.

The **Release** workflow checks that the tag matches `Ledger.toc`, builds the zip and publishes a GitHub
release (and uploads to CurseForge once that's set up). For a wider test before a real release, use a beta
version such as `0.9.2-beta1` in the `.toc` and the tag `v0.9.2-beta1`.
