# sven.nvim guide

Everything the [README](../README.md) leaves out: commands, keys, the popups, how staging works on top of Subversion, highlights, and how to run the tests.

## Commands

```vim
:Sven                         " status buffer of the working copy of the current directory
:Sven kind=split              " ... in a split (tab, split, vsplit, floating, replace, auto, ...)
:Sven cwd=~/src/wc            " ... of another working copy
:Sven commit                  " a popup: help, commit, log, diff, update, resolve
:Sven blame [file] [revision=N]   " blame a file, by default the current buffer's; again to close
```

From Lua: `require("sven").open { kind = "split", cwd = "~/src/wc" }`.

## Configuration

```lua
require("sven").setup {
  -- svn has no index. A file is "staged" when it is a member of this changelist.
  staging_changelist = "sven-staged",
  -- Everything else mirrors Neogit's setup: kind, mappings, sections, signs, highlight, ...
}
```

sven always runs `svn --non-interactive` and never prompts, so your repositories need cached credentials.

## Status buffer

```
Hint: <tab> za toggle | s stage | u unstage | x discard | c commit | ? help

Head:     r3 ^/trunk Change b.txt elsewhere
URL:      https://svn.example.org/repo/trunk

Conflicts (1)
conflicted   b.txt

Unversioned files (2)
new.txt
newdir/

Changes (1)
modified     a.txt

Changelist review (1)
added        other.txt

Staged changes (1)
modified     src/main.c

Recent commits
r3 Change b.txt elsewhere
r2 Add the initial files
```

The keys are Neogit's wherever svn has the same concept. `?` shows them all.

| Key | What it does |
| --- | --- |
| `<tab>`, `za`, `zo`, `zc` | Fold or unfold a section, a file (shows its diff) or a hunk |
| `1` `2` `3` `4` | Fold depth: sections, files, diffs, everything |
| `<c-n>` / `<c-p>`, `}` / `{` | Next and previous section, next and previous hunk |
| `s` | Stage the file, selection or section. On a conflicted file: mark it resolved and stage it |
| `S`, `<c-s>` | Stage all versioned changes, or those plus everything unversioned |
| `u`, `U` | Unstage the file, selection or section, or everything |
| `x` | Discard, after asking: delete an unversioned file, revert a file, revert one hunk, or revert only the selected lines of a hunk |
| `<cr>` | Open the file, at the line under the cursor when inside a hunk. On a recent commit: open the revision view |
| `<s-cr>`, `<c-x>`, `<c-v>`, `<c-t>` | Open the file in a peek split, split, vsplit or tab |
| `B` | Blame the file under the cursor |
| `Y` | Yank the path, or `r<rev>` on a commit |
| `<c-r>` | Refresh |
| `$` | History of the svn commands that were run, with their output |
| `Q` | Run an arbitrary svn command |
| `q` | Close |
| `c` `l` `d` `F` `r` `?` | Commit, log, diff, update, resolve and help popups |

The buffer refreshes when you write a file of the working copy, when Neovim regains focus, and when anything changes `.svn/wc.db`, so svn commands run in a terminal show up as well.

## Popups

**Commit (`c`)**: `c` commits the staged changes, and offers to commit everything when nothing is staged. `a` commits all changes, `f` only the file or selection under the cursor. The message editor lists what will be committed and can show its diff next to it. Submit with `<c-c><c-c>`, abort with `<c-c><c-k>`. A message whose commit failed is offered again on the next attempt.

**Update (`F`)**: `u` to HEAD, `r` to a revision, `f` only the file under the cursor. Conflicts are postponed by default and land in the Conflicts section. `-a` picks another `--accept` choice, `-d` a `--set-depth`.

**Resolve (`r`)**: resolve the conflicted file under the cursor (lower case) or every conflict (upper case) as `working`, `mine-full`, `theirs-full`, `base`, `mine-conflict` or `theirs-conflict`. The choices that drop your changes ask first.

**Log (`l`)**: `l` the working copy, `f` the file under the cursor, `r` the whole repository, `p` any path or URL, with `--limit`, `--search`, a revision range, `--stop-on-copy` and `--use-merge-history`. In the log view `<tab>` unfolds a revision to its message and changed paths, `<cr>` opens the revision view, `+` loads more, `d` opens the diff popup for that revision.

**Diff (`d`)**: `d` shows the change of what the cursor is on: for a file, inline in the file buffer against its BASE text when [unified.nvim](https://github.com/papricasix/unified.nvim) is installed (press it again, or `x`, to remove the marks); for a revision, the revision view. `w` all changes of the working copy, `s` the staged ones, `r` a revision, `f` a file in a revision, `R` a range. Without unified.nvim the diff popup uses sven's own diff buffer.

**Revision view**: revision, author, date, message, changed paths and the diff with foldable hunks. `<cr>` on a hunk opens the working file at that line.

**Blame** (`B`, `:Sven blame`): a gutter to the left of the file, bound to its scrolling, with revision, author and date per line. `<cr>` opens the revision of the line, `-` blames again as of the revision before it, `q` closes.

## How staging works

Subversion has no staging area, so sven uses a changelist as one. Staging a file puts it into the changelist named by `staging_changelist`, unstaging takes it out, and committing "the staged changes" commits the members of that changelist. Any other changelist you created yourself is shown as a section of its own.

That model has consequences worth knowing:

- Staging is per file. A file cannot be staged partially.
- A file is in at most one changelist. Staging a member of another changelist moves it.
- Changelists hold files only. Staging a directory stages the changed files inside it. A directory that is scheduled for addition is committed along with the staged files inside it. A directory that is scheduled for deletion is committed once everything inside it is staged, because svn deletes a directory as a whole.
- Staging an unversioned file runs `svn add` first, staging a missing file runs `svn delete`. Unstaging does not undo that.
- A change to a directory itself, such as a property change or an empty new directory, cannot be staged. Commit it with "commit all" or with `f` on that directory.

## Highlights

Every `Sven*` highlight group links to its `Neogit*` counterpart when that group exists, so a colorscheme with Neogit support styles sven as well. Groups without a counterpart are derived from your colorscheme the same way Neogit derives its own. Define a `Sven*` group yourself to override either.

## Development

The specs run in headless Neovim with [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s busted runner, against throwaway Subversion repositories created with `svnadmin`. They need `svn` and `svnadmin` on the `PATH`.

```sh
# Everything
make test

# One spec file, or one directory
make test TEST_FILES=tests/specs/sven/lib/svn/status_spec.lua
make test TEST_FILES=tests/specs/sven/lib/svn

# plenary.nvim is looked for in ~/.local/share/nvim/lazy/plenary.nvim. Elsewhere:
make test PLENARY_DIR=/path/to/plenary.nvim
```

Specs live in `tests/specs/` and end in `_spec.lua`. `tests/util/svn_harness.lua` creates a repository with a working copy of its trunk for a spec, and removes it afterwards:

```lua
local harness = require("tests.util.svn_harness")

describe("something", function()
  local wc

  before_each(function()
    wc = harness.create()
  end)

  after_each(function()
    harness.cleanup()
  end)

  it("sees a modification", function()
    wc:replace("a.txt", "line 2\n", "line 2 changed\n")

    local state = wc:refresh()

    assert.are.same("a.txt", state.changes.items[1].name)
  end)
end)
```

`make lint` checks the formatting with [StyLua](https://github.com/JohnnyMorganz/StyLua), `make format` applies it.
