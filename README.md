# repo-archives

Private snapshot archive for local git repos. Stores zip snapshots of tracked
files at `HEAD` for each configured repo, with a small rolling history.

## Usage

```
repo-archive <alias|path>
```

Examples:

```
repo-archive fmb
repo-archive /home/user/projects/some-other-repo
```

`repo-archive` is a global command (a symlink to `archive.sh` in this repo,
placed on `PATH` via `~/.local/bin`). Running it will:

1. Resolve the repo (alias from `repos.conf`, or a literal path).
2. Read the current branch, short/full commit SHA, and commit subject.
3. Warn (but not block) if the repo has uncommitted changes — the zip only
   ever contains the last committed state (`HEAD`), never working-tree edits.
4. Create `<repo_name>/<repo_name>_<YYYY-MM-DD>_<shortsha>.zip` in this repo,
   using `git archive` so only tracked files are included.
5. Update `<repo_name>/INDEX.md` with the entry (filename, date, branch, full
   SHA, commit subject).
6. Commit and push the change to this archives repo.

Re-running the same command on the same day against the same commit
overwrites that day's zip instead of creating a duplicate.

## Adding a repo

Add a line to `repos.conf` next to the script:

```
<alias>=/absolute/path/to/repo
```

The alias is only a shorthand for invoking the command — it is never used in
filenames. The archive filename always uses the target repo's directory
name (`basename` of its path).

## Retention

Each repo keeps at most **3** archived zips. When a 4th distinct snapshot is
added, the oldest zip file and its `INDEX.md` entry are removed.
