# WebUI Bridge Patch Guide (Codex Electron)

This guide documents exactly how `--webui` was added in the readable Codex build, how IPC was bridged to WebSocket, and how WebUI was exposed in a browser.

## Patched Files

- `/Users/igor/temp/untitled folder 67/codex_reverse/readable/.vite/build/main-BLcwFbOH.js`
- `/Users/igor/temp/untitled folder 67/codex_reverse/readable/webview/webui-bridge.js`
- `/Users/igor/temp/untitled folder 67/codex_reverse/readable/webview/assets/index-BnRAGF7J.js`
- `/Users/igor/temp/untitled folder 67/codex_reverse/readable/package.json`

## 1) Add `--webui` CLI mode

In main process bundle, parse CLI/env switches and keep options in `webUiOptions`.

```js
function webUiParseCliOptions(argv = process.argv, env = process.env) {
  let enabled = false;
  let remote = false;
  let port = webUiParsePortArg(env.CODEX_WEBUI_PORT, 3210);
  let token = (env.CODEX_WEBUI_TOKEN ?? "").trim();
  let origins = (env.CODEX_WEBUI_ORIGINS ?? "")
    .split(",")
    .map((x) => x.trim())
    .filter(Boolean);

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--webui") enabled = true;
    if (a === "--remote") remote = true;
    if (a === "--port" && i + 1 < argv.length) port = webUiParsePortArg(argv[++i], port);
    if (a.startsWith("--port=")) port = webUiParsePortArg(a.slice("--port=".length), port);
    if (a === "--token" && i + 1 < argv.length) token = String(argv[++i] ?? "").trim();
    if (a.startsWith("--token=")) token = a.slice("--token=".length).trim();
    if (a.startsWith("--origins=")) {
      origins = a.slice("--origins=".length).split(",").map((x) => x.trim()).filter(Boolean);
    }
  }
  return { enabled, remote, port, token, origins };
}
```

## 2) Split startup path (desktop vs web)

In `app.whenReady()`, do not create normal window when `--webui` is enabled.

```js
await Bp.refresh();
if (webUiOptions.enabled) {
  webUiBridgeWindow = await webUiCreateBridgeWindow();
  webUiRuntime = await webUiStartBridgeRuntime({
    bridgeWindow: webUiBridgeWindow,
    context: Dde,
  });
} else {
  await kc(Pt);
}
```

Also keep app alive in headless mode:

```js
electron.app.on("window-all-closed", () => {
  if (webUiOptions.enabled) return;
  if (process.platform !== "darwin") electron.app.quit();
});
```

## 3) Expose WebUI over HTTP + WebSocket

`webUiStartBridgeRuntime(...)` starts HTTP server and WS server:

- Bind host:
  - `127.0.0.1` for local mode
  - `0.0.0.0` for `--remote`
- Serve `webview` assets and SPA fallback
- Inject `webui-config.js` and `webui-bridge.js` into HTML
- Guard `/ws` with origin check and optional token auth

```js
const host = webUiOptions.remote ? "0.0.0.0" : "127.0.0.1";
const authRequired = webUiOptions.remote || !!webUiOptions.token;
const wss = new WebSocketServer({ noServer: true, perMessageDeflate: false });
```

Static serving with no-store cache (prevents stale frontend):

```js
res.setHeader("Cache-Control", "no-store");
```

## 4) IPC -> WebSocket bridge

Main trick: intercept `bridgeWindow.webContents.send` and mirror IPC events to WS packets.

```js
const originalSend = bridgeWindow.webContents.send.bind(bridgeWindow.webContents);
bridgeWindow.webContents.send = (channel, ...args) => {
  if (channel === bt) {
    broadcast({ kind: "message-for-view", payload: args[0] });
  } else if (channel.startsWith("codex_desktop:worker:") && channel.endsWith(":for-view")) {
    broadcast({
      kind: "worker-message-for-view",
      workerId: channel.slice("codex_desktop:worker:".length, -":for-view".length),
      payload: args[0],
    });
  }
  originalSend(channel, ...args);
};
```

Incoming WS -> existing electron message handler:

```js
if (packet?.kind === "message-from-view") {
  await context.handleMessage(bridgeWindow.webContents, packet.payload);
}
if (packet?.kind === "worker-message-from-view") {
  await webUiInvokeElectronBridgeMethod(bridgeWindow, "sendWorkerMessageFromView", [
    packet.workerId,
    packet.payload,
  ]);
}
```

## 5) Renderer web bridge (`window.electronBridge`)

In `webview/webui-bridge.js`, define the bridge only when preload bridge is absent.

```js
if (window.electronBridge?.sendMessageFromView) return;
```

Use WS adapter compatible with existing renderer message flow:

```js
window.electronBridge = {
  windowType: "web",
  sendMessageFromView: async (message) => sendPacket({ kind: "message-from-view", payload: message }),
  sendWorkerMessageFromView: async (workerId, message) =>
    sendPacket({ kind: "worker-message-from-view", workerId, payload: message }),
  subscribeToWorkerMessages: (...) => ...,
  getPathForFile: () => null,
};
```

Incoming WS packets are forwarded as browser `"message"` events:

```js
window.dispatchEvent(new MessageEvent("message", { data: packet.payload }));
```

## 6) Stability fixes added after testing

### A) Single active socket guard

Avoid duplicate WS sessions and duplicated events:

```js
let activeSocketToken = 0;
const currentToken = ++activeSocketToken;
if (currentToken !== activeSocketToken) return;
```

### B) Trigger refresh when connection is marked connected

In renderer state manager:

```js
F5("client-status-changed", (e) => {
  if (e.params.status === "connected") {
    this.refreshRecentConversations({ sortKey: this.recentConversationsSortKey }).catch(() => {});
    for (const id of this.streamingConversations) this.broadcastConversationSnapshot(id);
  }
});
```

### C) Explicitly emit `client-status-changed` on ready

In main message handler (`type: "ready"`):

```js
e.send(bt, {
  type: "ipc-broadcast",
  method: "client-status-changed",
  sourceClientId: "desktop",
  version: Fs("client-status-changed"),
  params: { status: "connected" },
});
```

### D) Raise local WS inbound rate limit

Prevent local bridge churn from very chatty frontend traffic:

```js
const inboundLimit = webUiOptions.remote ? 240 : 5000;
if (++count > inboundLimit) {
  ws.close(1008, "Rate limit exceeded");
}
```

## 7) Scripts and run commands

Added scripts in `package.json`:

```json
"webui": "NODE_ENV=production electron . --webui",
"webui:remote": "NODE_ENV=production electron . --webui --remote"
```

Launch example used during patching:

```bash
env \
  CODEX_CLI_PATH='/opt/homebrew/bin/codex' \
  CUSTOM_CLI_PATH='/opt/homebrew/bin/codex' \
  '/Users/igor/temp/untitled folder 67/codex_reverse/meta/electron-runner/node_modules/.bin/electron' \
  '/Users/igor/temp/untitled folder 67/codex_reverse/readable' \
  --webui --port 4310
```

Open:

```bash
open http://127.0.0.1:4310/
```

## 8) Notes when patching installed `.app`

- `app.asar` and `app.asar.unpacked` are coupled.
- Renaming archive without matching `.unpacked` path can break extraction tooling.
- Safest workflow is patching a copy of the app bundle, then replacing atomically.
