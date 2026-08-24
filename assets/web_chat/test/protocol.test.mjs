import test from 'node:test';
import assert from 'node:assert/strict';
import {
  captureAnchor,
  createFrameCoalescer,
  receiveTransferChunk,
  reduceEnvelope,
  restoreAnchor,
  visibleRange,
} from '../protocol.mjs';

test('transfer chunks reassemble UTF-8 snapshots', () => {
  const payload = { type: 'snapshot', content: '分片消息' };
  const bytes = new TextEncoder().encode(JSON.stringify(payload));
  const chunks = [bytes.slice(0, 5), bytes.slice(5)];
  let result = null;
  for (const [index, chunk] of chunks.entries()) {
    result = receiveTransferChunk({
      protocolVersion: 1,
      transferId: 'utf8-transfer',
      index,
      total: chunks.length,
      data: Buffer.from(chunk).toString('base64'),
    });
  }
  assert.deepEqual(result, payload);
});

test('snapshot reducer rejects an older revision in the same session', () => {
  const current = { type: 'snapshot', protocolVersion: 1, assetVersion: 'web-chat-v1', renderSessionId: 's', renderRevision: 4, messages: [] };
  const older = { ...current, renderRevision: 3, messages: [{ id: 'old' }] };
  assert.equal(reduceEnvelope(current, older), current);
});

test('message patches affect only the active render session', () => {
  const state = { renderSessionId: 's', conversationId: 'c', messages: [{ id: 'm', content: 'a' }] };
  const next = reduceEnvelope(state, { type: 'messagePatches', renderSessionId: 's', conversationId: 'c', patches: [{ id: 'm', content: 'b' }] });
  assert.equal(next.messages[0].content, 'b');
  assert.equal(reduceEnvelope(state, { type: 'messagePatches', renderSessionId: 'old', conversationId: 'c', patches: [] }), state);
});

test('virtual range grows with the viewport rather than total messages', () => {
  const range = visibleRange({ heights: new Array(360).fill(100), scrollTop: 12000, viewportHeight: 700, overscan: 300 });
  assert.ok(range.end - range.start < 20);
  assert.equal(range.top, range.start * 100);
});

test('frame coalescer runs once for a burst', () => {
  const frames = [];
  let calls = 0;
  const schedule = createFrameCoalescer(() => { calls += 1; }, (callback) => frames.push(callback));
  schedule(); schedule(); schedule();
  assert.equal(frames.length, 1);
  frames[0]();
  assert.equal(calls, 1);
});

test('anchor capture and restore preserve the message offset', () => {
  const nodes = [
    { dataset: { messageId: 'a' }, getBoundingClientRect: () => ({ top: -20, bottom: -1 }) },
    { dataset: { messageId: 'b' }, getBoundingClientRect: () => ({ top: 18, bottom: 118 }) },
  ];
  const container = {
    scrollTop: 100,
    getBoundingClientRect: () => ({ top: 10 }),
    querySelectorAll: () => nodes,
  };
  const anchor = captureAnchor(container);
  assert.deepEqual(anchor, { id: 'b', offset: 8 });
  nodes[1].getBoundingClientRect = () => ({ top: 24, bottom: 124 });
  restoreAnchor(container, anchor);
  assert.equal(container.scrollTop, 106);
});
