#!/bin/bash
# Substitutes the Supabase anon key into BuildConfig.swift for the duration of a build.
#
# The key is public by design (the landing page ships the same one in its JavaScript and every
# table behind it is protected by RLS), but keeping it out of a public repo is free, so the
# checked-in source carries a placeholder and the build fills it in.
#
#   BELAUNCHER_SUPABASE_ANON_KEY=… bash Scripts/with-anon-key.sh <command…>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/Sources/BeLauncher/BuildConfig.swift"
KEY="${BELAUNCHER_SUPABASE_ANON_KEY:-}"

if [ -z "$KEY" ]; then
    echo "warning: BELAUNCHER_SUPABASE_ANON_KEY is not set — activation will not reach the server"
    exec "$@"
fi

BACKUP="$(mktemp)"
cp "$CONFIG" "$BACKUP"
trap 'cp "$BACKUP" "$CONFIG"; rm -f "$BACKUP"' EXIT

# `|` as the delimiter: the key is base64url and never contains one.
sed -i '' "s|__SUPABASE_ANON_KEY__|$KEY|" "$CONFIG"
"$@"
