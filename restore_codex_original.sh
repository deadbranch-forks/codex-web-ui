#!/usr/bin/env bash
set -euo pipefail

# Restore original Codex files from backups created by launch_codex_webui.sh

CODEX_DIR="${CODEX_DIR:-$HOME/apps/CodexDesktop-Rebuild}"

restore_file() {
  local f="$1"
  if [[ -f "${f}.webui-backup" ]]; then
    cp "${f}.webui-backup" "$f"
    rm "${f}.webui-backup"
    echo "Restored: $f"
  else
    echo "No backup found for: $f"
  fi
}

MAIN_JS="$CODEX_DIR/src/.vite/build/main-WjwBKRS3.js"
INDEX_HTML="$CODEX_DIR/src/webview/index.html"

# Find renderer JS
RENDERER_JS_REL="$(sed -nE 's@.*src="./assets/(index-[A-Za-z0-9_-]+\.js)".*@\1@p' "$INDEX_HTML" 2>/dev/null | head -n1)"
if [[ -z "$RENDERER_JS_REL" ]] && [[ -f "${INDEX_HTML}.webui-backup" ]]; then
  RENDERER_JS_REL="$(sed -nE 's@.*src="./assets/(index-[A-Za-z0-9_-]+\.js)".*@\1@p' "${INDEX_HTML}.webui-backup" | head -n1)"
fi
RENDERER_JS="$CODEX_DIR/src/webview/assets/$RENDERER_JS_REL"

restore_file "$MAIN_JS"
[[ -n "$RENDERER_JS_REL" ]] && restore_file "$RENDERER_JS"
restore_file "$INDEX_HTML"

# Remove bridge file from webview
if [[ -f "$CODEX_DIR/src/webview/webui-bridge.js" ]]; then
  rm "$CODEX_DIR/src/webview/webui-bridge.js"
  echo "Removed: webui-bridge.js from webview"
fi

echo "Restore complete."
