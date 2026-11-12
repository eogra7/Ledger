# Contributing to Ledger

Thanks for helping. Pull requests are welcome from anyone: you don't need access to this repo.

## The one hard rule

Ledger is **read-only**. It never buys, sells, posts, cancels or mails anything, and never clicks anything on
your behalf. It only reads (mail invoices, bags, AH searches you start) and shows. Changes that automate
auction house or other gameplay actions won't be merged. They'd also break Blizzard's add-on policy.

## How to contribute

1. Create a branch (`git checkout -b fix-anvil-filter`). Collaborators can push branches to this repo; anyone
   else forks it first. Nobody pushes to `main` directly: every change goes through a pull request.
2. Make your change. Keep to the existing style: plain Lua 5.1, no libraries, money in copper.
3. Run the tests (below) and add one if you changed logic in `Core.lua`, `Craft.lua` or `Live.lua`.
4. Try it in game (below).
5. Open a pull request against `main` with a [Conventional Commit](#commit-and-pr-titles) title, and fill in
   the checklist.

Every pull request runs the **Checks** workflow: tests, a test build, the title check and the review check.
The maintainer is asked to review automatically. Once they approve the latest commit and the checks pass, they
merge it (pull requests are squash-merged, so the PR title becomes the commit on `main`). The maintainer's own
pull requests merge themselves when the checks pass.

## Commit and PR titles

Titles follow [Conventional Commits](https://www.conventionalcommits.org/): `type(optional scope): what changed`.

| Type | For | Release |
|---|---|---|
| `feat` | a new feature (`feat(craft): leatherworking support`) | minor: 0.10.0 → 0.11.0 |
| `fix` | a bug fix (`fix(portfolio): sales counted twice`) | patch: 0.10.0 → 0.10.1 |
| `perf` | faster, same behaviour | patch |
| `docs`, `ci`, `test`, `refactor`, `style`, `build`, `chore`, `revert` | everything else | none on its own |

Add `!` after the type (`feat!: ...`), or a `BREAKING CHANGE:` line in the description, for a change that
breaks something users rely on, such as saved data or a command: that bumps the major version. The PR title
is what counts, since it becomes the squash commit; commits inside the branch can be named anything.

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

Each pull request's **Checks** run also builds an installable zip, packaged exactly like a release:

1. Open the pull request's **Checks** tab, then the **Checks** run (its **build** job).
2. Under **Artifacts**, download the `Ledger-<version>-forever.zip` (you need to be signed in to GitHub).
3. Delete your `Interface\AddOns\Ledger` folder, unzip the download into `Interface\AddOns\`, and `/reload`.
4. Check what the PR changed, plus a quick look at each tab. The numbered **Test steps** in the README cover
   most features.

Back up your `WTF\Account\<account>\SavedVariables\Ledger.lua` first if you care about your history: a buggy
build can write bad data into it.

## Releases

Versions are worked out from the commit titles (SemVer), so nobody edits a version number. `Ledger.toc` says
`@project-version@`, which the packager fills in.

- **Alpha, automatic:** when a pull request with a `feat`, `fix`, `perf` or breaking change merges, the
  **Release** workflow publishes the next version as an alpha, e.g. `v0.10.0-alpha.1`, then `-alpha.2` for the
  next fix. Alphas are GitHub pre-releases (and CurseForge alphas once that's set up). Docs-only or CI-only
  merges don't make one.
- **Release, after testing:** once an alpha has been tried in game, go to **Actions > Release > Run
  workflow**, keep mode **promote**, and optionally name the alpha (blank = the newest). The maintainer
  approves the run in the **release** environment; that approval is the "tested" sign-off. The same commit is
  tagged `v0.10.0` and published as a full release, with a changelog of everything since the last release.
