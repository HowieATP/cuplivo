export const PROTOCOL_VERSION = 1;
export const ASSET_VERSION = 'web-chat-v1';

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
  if (!anchor) return;
  const node = [...container.querySelectorAll('[data-message-id]')]
    .find((item) => item.dataset.messageId === anchor.id);
  if (!node) return;
  const top = container.getBoundingClientRect().top;
  container.scrollTop += node.getBoundingClientRect().top - top - anchor.offset;
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
