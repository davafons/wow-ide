#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_app="$repo_dir/dist/WoW IDE.app"
target_app="/Applications/WoW IDE.app"

if pgrep -f '^/Applications/WoW IDE\.app/' >/dev/null; then
    echo "Quit WoW IDE before installing a new development build." >&2
    exit 1
fi

"$repo_dir/scripts/package-internal.sh"
/usr/bin/ditto "$source_app" "$target_app"
/usr/bin/codesign --verify --strict "$target_app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$target_app"
/usr/bin/mdimport "$target_app" || true

printf 'Installed development build: %s\n' "$target_app"
