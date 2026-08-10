#!/usr/bin/env bash
# repo-archive: zip-snapshot a local git repo into this archives repo, keeping the 3 newest per repo.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: repo-archive <alias-or-path>" >&2
  exit 1
fi

arg="$1"

# Resolve the real script location through symlinks so repos.conf is found next to it.
script_path="$(readlink -f "$0")"
script_dir="$(dirname "$script_path")"
conf_file="${script_dir}/repos.conf"
ARCHIVE_ROOT="$script_dir"

# Serialize concurrent runs -- two archive calls racing the same INDEX.md
# read-modify-write (or the same git add/commit) would corrupt one or both.
exec 200>"${ARCHIVE_ROOT}/.archive.lock"
flock -n 200 || { echo "another archive run in progress" >&2; exit 1; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

target_path=""
if [ -f "$conf_file" ]; then
  while IFS='=' read -r alias_name alias_path; do
    alias_name="$(trim "$alias_name")"
    alias_path="$(trim "$alias_path")"
    # skip blank lines and comments (trimmed first, so leading-whitespace
    # comments like "  # note" are caught too)
    [ -z "$alias_name" ] && continue
    case "$alias_name" in \#*) continue ;; esac
    if [ "$alias_name" = "$arg" ]; then
      target_path="$alias_path"
      break
    fi
  done < "$conf_file"
fi

if [ -z "$target_path" ]; then
  target_path="$arg"
fi

if [ ! -d "$target_path" ]; then
  echo "Error: path does not exist: $target_path" >&2
  exit 1
fi

target_path="$(readlink -f "$target_path")"

if ! git -C "$target_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: not a git repo: $target_path" >&2
  exit 1
fi

repo_name="$(basename "$target_path")"

branch="$(git -C "$target_path" rev-parse --abbrev-ref HEAD)"
short_sha="$(git -C "$target_path" rev-parse --short=8 HEAD)"
full_sha="$(git -C "$target_path" rev-parse HEAD)"
commit_subject="$(git -C "$target_path" log -1 --pretty=%s)"

if [ -n "$(git -C "$target_path" status --porcelain)" ]; then
  echo "Warning: $repo_name has uncommitted changes; they are NOT included (zip = HEAD snapshot)." >&2
fi

date_str="$(date +%Y-%m-%d)"

out_dir="${script_dir}/${repo_name}"
mkdir -p "$out_dir"

zip_name="${repo_name}_${date_str}_${short_sha}.zip"
zip_path="${out_dir}/${zip_name}"

git -C "$target_path" archive --format=zip -o "$zip_path" HEAD

index_file="${out_dir}/INDEX.md"

# Build the new entry line: filename | date | branch | full sha | subject
new_entry="| ${zip_name} | ${date_str} | ${branch} | ${full_sha} | ${commit_subject} |"

if [ ! -f "$index_file" ]; then
  {
    echo "# Archive index: ${repo_name}"
    echo ""
    echo "| Filename | Date | Branch | Full SHA | Commit Subject |"
    echo "|---|---|---|---|---|"
  } > "$index_file"
fi

# Collect existing entry lines (skip header/title/blank lines), keyed by filename.
existing_entries="$(grep -E '^\| ' "$index_file" | grep -v '^| Filename ' | grep -v '^|---' || true)"

updated_entries=""
found_existing="false"
if [ -n "$existing_entries" ]; then
  while IFS= read -r line; do
    entry_zip_name="$(echo "$line" | awk -F'|' '{print $2}' | xargs)"
    if [ "$entry_zip_name" = "$zip_name" ]; then
      updated_entries="${updated_entries}${new_entry}"$'\n'
      found_existing="true"
    else
      updated_entries="${updated_entries}${line}"$'\n'
    fi
  done <<< "$existing_entries"
fi

if [ "$found_existing" = "false" ]; then
  updated_entries="${updated_entries}${new_entry}"$'\n'
fi

# Trim trailing blank line artifact from the loop.
updated_entries="$(echo "$updated_entries" | sed '/^$/d')"

entry_count="$(echo "$updated_entries" | grep -c '^| ' || true)"

# `while`, not `if` -- a hand-edited INDEX.md can carry more than one entry
# past the retention limit, and a single trim step would leave it still
# over the cap.
while [ "$entry_count" -gt 3 ]; do
  oldest_line="$(echo "$updated_entries" | head -n 1)"
  oldest_zip_name="$(echo "$oldest_line" | awk -F'|' '{print $2}' | xargs)"
  oldest_zip_path="${out_dir}/${oldest_zip_name}"
  if [ -f "$oldest_zip_path" ]; then
    rm -f "$oldest_zip_path"
  fi
  updated_entries="$(echo "$updated_entries" | tail -n +2)"
  entry_count="$(echo "$updated_entries" | grep -c '^| ' || true)"
done

{
  echo "# Archive index: ${repo_name}"
  echo ""
  echo "| Filename | Date | Branch | Full SHA | Commit Subject |"
  echo "|---|---|---|---|---|"
  echo "$updated_entries"
} > "$index_file"

cd "$script_dir"
git add -A

if git diff --cached --quiet; then
  echo "No changes to commit; skipping commit/push."
  exit 0
fi

git commit -m "backup: ${repo_name} @ ${short_sha} (${date_str})" >/dev/null
git push

echo "Archived ${repo_name} @ ${short_sha} -> ${zip_path}"
