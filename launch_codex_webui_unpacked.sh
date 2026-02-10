#!/usr/bin/env bash
set -euo pipefail

APP_PATH="/Applications/Codex.app"
APP_ASAR="$APP_PATH/Contents/Resources/app.asar"
CLI_PATH="$APP_PATH/Contents/Resources/codex"
PATCH_BASE="/Users/igor/temp/untitled folder 67/codex_reverse/readable"
DEPS_DIR="${CODEX_WEBUI_PATCH_DEPS:-$HOME/.cache/codex-webui-patch-deps}"
PORT="${CODEX_WEBUI_PORT:-4310}"
REMOTE=0
KEEP_TEMP=0
NO_OPEN=0
USER_DATA_DIR=""

usage() {
  cat <<'USAGE'
Usage:
  launch_codex_webui_unpacked.sh [options] [-- <extra args>]

Options:
  --app <path>           Codex.app path
  --patch-base <path>    patched readable source path
  --deps-dir <path>      cache dir for ws/mime-types deps
  --port <n>             webui port (default: 4310)
  --remote               pass --remote
  --user-data-dir <path> chromium user data dir override
  --no-open              don't open browser
  --keep-temp            keep temp extracted app dir
  -h, --help
USAGE
}

EXTRA_ARGS=()
while (($#)); do
  case "$1" in
    --app)
      APP_PATH="${2:?missing value}"; APP_ASAR="$APP_PATH/Contents/Resources/app.asar"; CLI_PATH="$APP_PATH/Contents/Resources/codex"; shift 2 ;;
    --patch-base)
      PATCH_BASE="${2:?missing value}"; shift 2 ;;
    --deps-dir)
      DEPS_DIR="${2:?missing value}"; shift 2 ;;
    --port)
      PORT="${2:?missing value}"; shift 2 ;;
    --remote)
      REMOTE=1; shift ;;
    --user-data-dir)
      USER_DATA_DIR="${2:?missing value}"; shift 2 ;;
    --no-open)
      NO_OPEN=1; shift ;;
    --keep-temp)
      KEEP_TEMP=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; EXTRA_ARGS+=("$@"); break ;;
    *)
      EXTRA_ARGS+=("$1"); shift ;;
  esac
done

[[ -f "$APP_ASAR" ]] || { echo "Missing app.asar: $APP_ASAR" >&2; exit 1; }
[[ -x "$CLI_PATH" ]] || { echo "Missing codex binary: $CLI_PATH" >&2; exit 1; }
[[ -f "$PATCH_BASE/.vite/build/main.js" ]] || { echo "Missing patch main.js in $PATCH_BASE" >&2; exit 1; }
[[ -f "$PATCH_BASE/webview/index.html" ]] || { echo "Missing patch webview/index.html in $PATCH_BASE" >&2; exit 1; }
[[ -f "$PATCH_BASE/webview/webui-bridge.js" ]] || { echo "Missing patch webview/webui-bridge.js in $PATCH_BASE" >&2; exit 1; }

if [[ ! -d "$DEPS_DIR/node_modules/ws" || ! -d "$DEPS_DIR/node_modules/mime-types" || ! -d "$DEPS_DIR/node_modules/mime-db" ]]; then
  mkdir -p "$DEPS_DIR"
  [[ -f "$DEPS_DIR/package.json" ]] || cat > "$DEPS_DIR/package.json" <<'PKG'
{"name":"codex-webui-patch-deps","private":true}
PKG
  npm --prefix "$DEPS_DIR" install --no-audit --no-fund ws mime-types >/dev/null
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-webui-unpacked.XXXXXX")"
APP_DIR="$WORKDIR/app"
if [[ -z "$USER_DATA_DIR" ]]; then
  USER_DATA_DIR="$WORKDIR/user-data"
fi

cleanup() {
  if [[ "$KEEP_TEMP" -eq 0 ]]; then
    rm -rf "$WORKDIR"
  else
    echo "Kept temp dir: $WORKDIR"
  fi
}
trap cleanup EXIT

echo "Extracting app.asar to: $APP_DIR"
npx -y @electron/asar extract "$APP_ASAR" "$APP_DIR"

target_main_js_rel="$(sed -nE 's@.*(main-[A-Za-z0-9_-]+\.js).*@\1@p' "$APP_DIR/.vite/build/main.js" | head -n1 || true)"
source_main_js_rel="$(sed -nE 's@.*(main-[A-Za-z0-9_-]+\.js).*@\1@p' "$PATCH_BASE/.vite/build/main.js" | head -n1 || true)"
target_renderer_js_rel="$(sed -nE 's@.*assets/(index-[A-Za-z0-9_-]+\.js).*@\1@p' "$APP_DIR/webview/index.html" | head -n1 || true)"
source_renderer_js_rel="$(sed -nE 's@.*assets/(index-[A-Za-z0-9_-]+\.js).*@\1@p' "$PATCH_BASE/webview/index.html" | head -n1 || true)"

[[ -n "$target_main_js_rel" && -n "$source_main_js_rel" && -n "$target_renderer_js_rel" && -n "$source_renderer_js_rel" ]] || {
  echo "Failed resolving hashed bundle names" >&2; exit 1;
}

echo "Applying unpacked patches"
cp "$PATCH_BASE/.vite/build/$source_main_js_rel" "$APP_DIR/.vite/build/$target_main_js_rel"
cp "$PATCH_BASE/webview/assets/$source_renderer_js_rel" "$APP_DIR/webview/assets/$target_renderer_js_rel"
cp "$PATCH_BASE/webview/webui-bridge.js" "$APP_DIR/webview/webui-bridge.js"
mkdir -p "$APP_DIR/node_modules"
cp -R "$DEPS_DIR/node_modules/ws" "$APP_DIR/node_modules/ws"
cp -R "$DEPS_DIR/node_modules/mime-types" "$APP_DIR/node_modules/mime-types"
cp -R "$DEPS_DIR/node_modules/mime-db" "$APP_DIR/node_modules/mime-db"

rg -q -- '--webui' "$APP_DIR/.vite/build/$target_main_js_rel" || { echo "Patched main missing --webui" >&2; exit 1; }

CMD=(npx electron "--user-data-dir=$USER_DATA_DIR" "$APP_DIR" --webui --port "$PORT")
if [[ "$REMOTE" -eq 1 ]]; then
  CMD+=(--remote)
fi
if ((${#EXTRA_ARGS[@]})); then
  CMD+=("${EXTRA_ARGS[@]}")
fi

unset ELECTRON_RUN_AS_NODE
export ELECTRON_FORCE_IS_PACKAGED=true
export CODEX_CLI_PATH="$CLI_PATH"
export CUSTOM_CLI_PATH="$CLI_PATH"

echo "App dir: $APP_DIR"
echo "User data dir: $USER_DATA_DIR"
printf 'Command:'; printf ' %q' "${CMD[@]}"; echo

if [[ "$NO_OPEN" -eq 0 ]]; then
  ( sleep 1; open "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 || true ) &
fi

exec "${CMD[@]}"
