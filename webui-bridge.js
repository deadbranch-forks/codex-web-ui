(() => {
  if (typeof window === "undefined") return;
  if (window.electronBridge?.sendMessageFromView) return;

  const runtimeConfig = window.__CODEX_WEBUI_CONFIG__ ?? {};
  const workerSubscribers = new Map();
  const outboundQueue = [];
  const bootstrapTimers = [];
  const appRoutesRecoveryKey = "__codex_webui_app_routes_recovery_count";
  const maxAppRoutesRecoveries = 1;

  const reconnectBaseMs = 500;
  const reconnectMaxMs = 5000;
  let reconnectAttempt = 0;
  let reconnectTimer = null;
  let socket = null;
  let isOpen = false;
  let activeSocketToken = 0;

  const wsProtocol = window.location.protocol === "https:" ? "wss:" : "ws:";
  const wsPath =
    typeof runtimeConfig.wsPath === "string" && runtimeConfig.wsPath.length > 0
      ? runtimeConfig.wsPath
      : "/ws";
  const wsUrl = new URL(wsPath, `${wsProtocol}//${window.location.host}`);

  const flushQueue = () => {
    if (!isOpen || !socket || socket.readyState !== WebSocket.OPEN) return;
    while (outboundQueue.length > 0) {
      const payload = outboundQueue.shift();
      if (typeof payload === "string") socket.send(payload);
    }
  };

  const sendPacket = (packet) => {
    const serialized = JSON.stringify(packet);
    if (isOpen && socket && socket.readyState === WebSocket.OPEN) {
      socket.send(serialized);
      return;
    }
    outboundQueue.push(serialized);
  };

  const emitWorkerMessage = (workerId, payload) => {
    const subscribers = workerSubscribers.get(workerId);
    if (!subscribers) return;
    subscribers.forEach((subscriber) => {
      try {
        subscriber(payload);
      } catch (error) {
        console.warn("Worker subscription handler failed", error);
      }
    });
  };

  const handleInboundPacket = (packet) => {
    if (!packet || typeof packet !== "object") return;
    if (packet.kind === "message-for-view") {
      window.dispatchEvent(
        new MessageEvent("message", {
          data: packet.payload,
        }),
      );
      return;
    }
    if (packet.kind === "worker-message-for-view") {
      if (typeof packet.workerId === "string") {
        emitWorkerMessage(packet.workerId, packet.payload);
      }
      return;
    }
    if (packet.kind === "bridge-error") {
      console.warn("Codex WebUI bridge error", packet.message ?? "unknown");
    }
  };

  const getRecoveryCount = () => {
    try {
      const raw = window.sessionStorage.getItem(appRoutesRecoveryKey);
      const parsed = Number.parseInt(raw ?? "0", 10);
      return Number.isFinite(parsed) && parsed >= 0 ? parsed : 0;
    } catch {
      return 0;
    }
  };

  const setRecoveryCount = (value) => {
    try {
      window.sessionStorage.setItem(appRoutesRecoveryKey, String(value));
    } catch {
      // Ignore storage failures in restricted contexts.
    }
  };

  const maybeAutoRecoverFromAppRoutesError = (message) => {
    const text = typeof message?.message === "string" ? message.message : "";
    if (!text.includes("[ErrorBoundary:AppRoutes]")) return;
    const count = getRecoveryCount();
    if (count >= maxAppRoutesRecoveries) return;
    setRecoveryCount(count + 1);
    console.warn(
      "Codex WebUI: AppRoutes crash detected, reloading once for recovery.",
    );
    window.setTimeout(() => {
      window.location.reload();
    }, 150);
  };

  const scheduleReconnect = () => {
    if (socket && socket.readyState === WebSocket.OPEN) return;
    if (reconnectTimer != null) return;
    const delay = Math.min(
      reconnectMaxMs,
      reconnectBaseMs * 2 ** reconnectAttempt,
    );
    reconnectAttempt += 1;
    reconnectTimer = window.setTimeout(() => {
      reconnectTimer = null;
      connect();
    }, delay);
  };

  const clearBootstrapTimers = () => {
    while (bootstrapTimers.length > 0) {
      const timer = bootstrapTimers.pop();
      if (timer != null) window.clearTimeout(timer);
    }
  };

  const emitConnectedStatus = () => {
    window.dispatchEvent(
      new MessageEvent("message", {
        data: {
          type: "ipc-broadcast",
          method: "client-status-changed",
          sourceClientId: null,
          version: 0,
          params: { status: "connected" },
        },
      }),
    );
  };

  const kickBootstrapState = () => {
    emitConnectedStatus();
    sendPacket({
      kind: "message-from-view",
      payload: { type: "ready" },
    });
  };

  const connect = () => {
    if (
      socket &&
      (socket.readyState === WebSocket.CONNECTING ||
        socket.readyState === WebSocket.OPEN)
    ) {
      return;
    }
    const currentToken = ++activeSocketToken;
    const nextSocket = new WebSocket(wsUrl.toString());
    socket = nextSocket;
    nextSocket.addEventListener("open", () => {
      if (currentToken !== activeSocketToken) return;
      isOpen = true;
      reconnectAttempt = 0;
      flushQueue();
      kickBootstrapState();
      clearBootstrapTimers();
      for (const delayMs of [800, 2200]) {
        const timer = window.setTimeout(() => {
          if (currentToken !== activeSocketToken || !isOpen) return;
          kickBootstrapState();
        }, delayMs);
        bootstrapTimers.push(timer);
      }
    });
    nextSocket.addEventListener("message", (event) => {
      if (currentToken !== activeSocketToken) return;
      let packet;
      try {
        packet = JSON.parse(String(event.data));
      } catch {
        return;
      }
      handleInboundPacket(packet);
    });
    nextSocket.addEventListener("close", () => {
      if (currentToken !== activeSocketToken) return;
      socket = null;
      isOpen = false;
      clearBootstrapTimers();
      scheduleReconnect();
    });
    nextSocket.addEventListener("error", () => {
      if (currentToken !== activeSocketToken) return;
      isOpen = false;
    });
  };

  connect();

  window.codexWindowType = "web";
  window.electronBridge = {
    windowType: "web",
    sendMessageFromView: async (message) => {
      maybeAutoRecoverFromAppRoutesError(message);
      sendPacket({
        kind: "message-from-view",
        payload: message,
      });
    },
    getPathForFile: () => null,
    sendWorkerMessageFromView: async (workerId, message) => {
      sendPacket({
        kind: "worker-message-from-view",
        workerId,
        payload: message,
      });
    },
    subscribeToWorkerMessages: (workerId, callback) => {
      let subscribers = workerSubscribers.get(workerId);
      if (!subscribers) {
        subscribers = new Set();
        workerSubscribers.set(workerId, subscribers);
      }
      subscribers.add(callback);
      return () => {
        const activeSubscribers = workerSubscribers.get(workerId);
        if (!activeSubscribers) return;
        activeSubscribers.delete(callback);
        if (activeSubscribers.size === 0) {
          workerSubscribers.delete(workerId);
        }
      };
    },
    showContextMenu: async () => null,
    triggerSentryTestError: async () => {
      sendPacket({
        kind: "trigger-sentry-test",
      });
    },
    getSentryInitOptions: () => runtimeConfig.sentryInitOptions ?? null,
    getAppSessionId: () =>
      runtimeConfig.appSessionId ??
      runtimeConfig.sentryInitOptions?.codexAppSessionId ??
      null,
    getBuildFlavor: () => runtimeConfig.buildFlavor ?? "prod",
  };
})();
