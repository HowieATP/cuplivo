export const PROTOCOL_VERSION = 2;
export const ASSET_VERSION = 'web-chat-v4';

const transfers = new Map();

export function receiveTransferChunk(chunk) {
  if (chunk.protocolVersion !== PROTOCOL_VERSION) {
    throw new Error('protocol_mismatch');
  }
  if (!Number.isInteger(chunk.index) || !Number.isInteger(chunk.total) ||
      chunk.index < 0 || chunk.index >= chunk.total || chunk.total < 1) {
    throw new Error('invalid_transfer_sequence');
  }
  let transfer = transfers.get(chunk.transferId);
  if (!transfer) {
    transfer = { total: chunk.total, chunks: new Array(chunk.total) };
    transfers.set(chunk.transferId, transfer);
  }
  if (transfer.total !== chunk.total) throw new Error('transfer_total_changed');
  if (typeof chunk.data !== 'string') throw new Error('invalid_transfer_data');
  transfer.chunks[chunk.index] = chunk.data;
  for (let index = 0; index < transfer.total; index += 1) {
    if (typeof transfer.chunks[index] !== 'string') return null;
  }
  transfers.delete(chunk.transferId);
  const bytes = [];
  for (const encoded of transfer.chunks) {
    const binary = atob(encoded);
    for (let index = 0; index < binary.length; index += 1) {
      bytes.push(binary.charCodeAt(index));
    }
  }
  return JSON.parse(new TextDecoder().decode(new Uint8Array(bytes)));
}

export function reduceEnvelope(state, envelope) {
  if (envelope.type === 'snapshot') {
    if (envelope.protocolVersion !== PROTOCOL_VERSION ||
        envelope.assetVersion !== ASSET_VERSION) {
      throw new Error('snapshot_version_mismatch');
    }
    if (state && state.renderSessionId === envelope.renderSessionId &&
        Number(envelope.renderRevision) < Number(state.renderRevision)) {
      return state;
    }
    if (state?.renderSessionId === envelope.renderSessionId) {
      return {
        ...envelope,
        media: { ...(state.media ?? {}), ...(envelope.media ?? {}) },
      };
    }
    return envelope;
  }
  if (envelope.type === 'messagePatches') {
    if (!state || envelope.renderSessionId !== state.renderSessionId ||
        envelope.conversationId !== state.conversationId) return state;
    const byId = new Map(envelope.patches.map((patch) => [patch.id, patch]));
    return {
      ...state,
      messages: state.messages.map((message) =>
        byId.has(message.id) ? { ...message, ...byId.get(message.id) } : message),
    };
  }
  return state;
}

export function visibleRange({ heights, scrollTop, viewportHeight, overscan = 700 }) {
  const lower = Math.max(0, scrollTop - overscan);
  const upper = scrollTop + viewportHeight + overscan;
  let offset = 0;
  let start = 0;
  while (start < heights.length && offset + heights[start] < lower) {
    offset += heights[start];
    start += 1;
  }
  let end = start;
  let cursor = offset;
  while (end < heights.length && cursor < upper) {
    cursor += heights[end];
    end += 1;
  }
  return { start, end, top: offset, bottom: heights.slice(end).reduce((a, b) => a + b, 0) };
}

export function rangeChanged(previous, next) {
  return previous.start !== next.start || previous.end !== next.end;
}

export function normalizeContentInset(value, fallback = 8) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0
    ? value
    : fallback;
}

export function createExpansionCoordinator() {
  const entries = new Map();
  const requests = new Map();

  function reconcile(key, authoritative) {
    const value = Boolean(authoritative);
    const entry = entries.get(key);
    if (!entry) return null;
    entry.authoritative = value;
    if (entry.inFlight == null && entry.awaitingTarget === value) {
      entry.desired = value;
      entry.awaitingTarget = null;
    }
    if (entry.inFlight == null && entry.awaitingTarget == null &&
        entry.desired === entry.authoritative) {
      entries.delete(key);
      return null;
    }
    return entry;
  }

  function dispatch(entry) {
    const target = entry.desired;
    const requestId = entry.dispatch(target);
    if (typeof requestId !== 'string' || requestId.length === 0) {
      throw new Error('invalid_expansion_request');
    }
    entry.inFlight = { requestId, target };
    requests.set(requestId, entry.key);
  }

  return {
    value(key, authoritative) {
      const entry = reconcile(key, authoritative);
      return entry?.desired ?? Boolean(authoritative);
    },

    toggle({ key, authoritative, dispatch: send }) {
      let entry = reconcile(key, authoritative);
      if (!entry) {
        entry = {
          key,
          authoritative: Boolean(authoritative),
          desired: Boolean(authoritative),
          awaitingTarget: null,
          inFlight: null,
          dispatch: send,
        };
        entries.set(key, entry);
      } else {
        entry.dispatch = send;
      }
      entry.desired = !entry.desired;
      if (entry.awaitingTarget != null) entry.awaitingTarget = null;
      if (entry.inFlight == null) dispatch(entry);
      return entry.desired;
    },

    resolve(requestId, ok) {
      const key = requests.get(requestId);
      if (!key) return false;
      requests.delete(requestId);
      const entry = entries.get(key);
      if (!entry || entry.inFlight?.requestId !== requestId) return false;
      const completedTarget = entry.inFlight.target;
      entry.inFlight = null;
      if (!ok) {
        entry.desired = entry.authoritative;
        entry.awaitingTarget = null;
        entries.delete(key);
        return true;
      }
      if (entry.desired !== completedTarget) {
        dispatch(entry);
      } else if (entry.authoritative === completedTarget) {
        entries.delete(key);
      } else {
        entry.awaitingTarget = completedTarget;
      }
      return true;
    },

    clear() {
      entries.clear();
      requests.clear();
    },
  };
}

export function captureAnchor(container) {
  const top = container.getBoundingClientRect().top;
  for (const node of container.querySelectorAll('[data-message-id]')) {
    const rect = node.getBoundingClientRect();
    if (rect.bottom >= top) {
      return { id: node.dataset.messageId, offset: rect.top - top };
    }
  }
  return null;
}

export function restoreAnchor(container, anchor) {
  if (!anchor) return false;
  const node = [...container.querySelectorAll('[data-message-id]')]
    .find((item) => item.dataset.messageId === anchor.id);
  if (!node) return false;
  const top = container.getBoundingClientRect().top;
  container.scrollTop += node.getBoundingClientRect().top - top - anchor.offset;
  return true;
}

export function captureViewport(container, { preserve = true } = {}) {
  const viewportHeight = normalizeContentInset(container.clientHeight, 0);
  if (!preserve) {
    return { scrollTop: 0, viewportHeight, anchor: null };
  }
  const rawScrollTop = Number(container.scrollTop);
  return {
    scrollTop: Number.isFinite(rawScrollTop) ? Math.max(0, rawScrollTop) : 0,
    viewportHeight,
    anchor: captureAnchor(container),
  };
}

export function restoreViewport(container, viewport) {
  if (!viewport || restoreAnchor(container, viewport.anchor)) return;
  const rawScrollTop = Number(viewport.scrollTop);
  const rawScrollHeight = Number(container.scrollHeight);
  const rawClientHeight = Number(container.clientHeight);
  const scrollTop = Number.isFinite(rawScrollTop)
    ? Math.max(0, rawScrollTop)
    : 0;
  const scrollHeight = Number.isFinite(rawScrollHeight)
    ? Math.max(0, rawScrollHeight)
    : 0;
  const clientHeight = Number.isFinite(rawClientHeight)
    ? Math.max(0, rawClientHeight)
    : 0;
  container.scrollTop = Math.min(scrollTop, Math.max(0, scrollHeight - clientHeight));
}

export function createFrameCoalescer(callback, schedule = requestAnimationFrame) {
  let pending = false;
  return () => {
    if (pending) return;
    pending = true;
    schedule(() => {
      pending = false;
      callback();
    });
  };
}

export function createRenderGate(dispatch) {
  let blocked = false;
  let pending = false;
  return {
    request() {
      if (blocked) {
        pending = true;
        return;
      }
      dispatch();
    },

    setBlocked(value) {
      const next = Boolean(value);
      if (blocked === next) return;
      blocked = next;
      if (!blocked && pending) {
        pending = false;
        dispatch();
      }
    },

    get blocked() { return blocked; },
    get pending() { return pending; },
  };
}
