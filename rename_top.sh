#!/bin/sh
# Rename the top module to tt_um_<github_username>_tinyrv32e, as Tiny Tapeout
# requires a unique, username-prefixed name. Run once before pushing:
#   ./rename_top.sh your_github_username
set -e
cd "$(dirname "$0")"
[ -n "$1" ] || { echo "usage: $0 <github_username>"; exit 1; }
user=$(printf '%s' "$1" | tr -c 'A-Za-z0-9_\n' '_')
new="tt_um_${user}_tinyrv32e"
grep -q "tt_um_tinyrv32e" src/project.v || { echo "already renamed"; exit 1; }
for f in src/project.v info.yaml test/tb.v synth/run.sh README.md; do
  [ -f "$f" ] && sed -i "s/tt_um_tinyrv32e\b/$new/g" "$f"
done
echo "top module is now $new"
