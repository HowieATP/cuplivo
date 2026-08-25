import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  captureAnchor,
  createExpansionCoordinator,
  createFrameCoalescer,
  rangeChanged,
  receiveTransferChunk,
  reduceEnvelope,
  restoreAnchor,
  visibleRange,
} from '../protocol.mjs';

const appSource = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
const styleSource = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');

test('transfer chunks reassemble UTF-8 snapshots', () => {
  const payload = { type: 'snapshot', content: '分片消息' };
  const bytes = new TextEncoder().encode(JSON.stringify(payload));
  const chunks = [bytes.slice(0, 5), bytes.slice(5)];
  let result = null;
  for (const [index, chunk] of chunks.entries()) {
    result = receiveTransferChunk({
      protocolVersion: 2,
      transferId: 'utf8-transfer',
      index,
      total: chunks.length,
      data: Buffer.from(chunk).toString('base64'),
    });
  }
  assert.deepEqual(result, payload);
});

test('snapshot reducer rejects an older revision in the same session', () => {
  const current = { type: 'snapshot', protocolVersion: 2, assetVersion: 'web-chat-v2', renderSessionId: 's', renderRevision: 4, messages: [] };
  const older = { ...current, renderRevision: 3, messages: [{ id: 'old' }] };
  assert.equal(reduceEnvelope(current, older), current);
});

test('new snapshots retain resolved opaque media only in the same session', () => {
  const current = {
    type: 'snapshot', protocolVersion: 2, assetVersion: 'web-chat-v2',
    renderSessionId: 's', renderRevision: 4, messages: [],
    media: { 'asset:icon': 'data:image/svg+xml;base64,PHN2Zy8+' },
  };
  const next = { ...current, renderRevision: 5, media: undefined };
  const retained = reduceEnvelope(current, next);
  assert.equal(retained.media['asset:icon'], current.media['asset:icon']);

  const changedSession = { ...next, renderSessionId: 'other' };
  assert.equal(reduceEnvelope(current, changedSession).media, undefined);
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

test('measured heights rebuild only when the visible range changes', () => {
  assert.equal(
    rangeChanged({ start: 4, end: 12 }, { start: 4, end: 12 }),
    false,
  );
  assert.equal(
    rangeChanged({ start: 4, end: 12 }, { start: 3, end: 12 }),
    true,
  );
});

test('controlled expansion coalesces rapid clicks and ignores stale state', () => {
  const sent = [];
  const coordinator = createExpansionCoordinator();
  const dispatch = (target) => {
    const requestId = `r${sent.length + 1}`;
    sent.push({ requestId, target });
    return requestId;
  };

  coordinator.toggle({ key: 'reasoning', authoritative: false, dispatch });
  assert.equal(coordinator.value('reasoning', false), true);
  coordinator.toggle({ key: 'reasoning', authoritative: false, dispatch });
  assert.equal(coordinator.value('reasoning', false), false);
  assert.deepEqual(sent.map((item) => item.target), [true]);

  coordinator.resolve('r1', true);
  assert.deepEqual(sent.map((item) => item.target), [true, false]);
  assert.equal(coordinator.value('reasoning', true), false);
  coordinator.resolve('r2', true);
  assert.equal(coordinator.value('reasoning', false), false);
});

test('controlled expansion rolls back after a failed action', () => {
  const coordinator = createExpansionCoordinator();
  coordinator.toggle({
    key: 'reasoning',
    authoritative: false,
    dispatch: () => 'failed-request',
  });
  assert.equal(coordinator.value('reasoning', false), true);
  coordinator.resolve('failed-request', false);
  assert.equal(coordinator.value('reasoning', false), false);
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

test('mobile shell owns vertical gestures and uses controlled disclosures', () => {
  assert.match(styleSource, /touch-action:\s*pan-y/);
  assert.match(styleSource, /-webkit-overflow-scrolling:\s*touch/);
  assert.doesNotMatch(appSource, /createElement\(['"]details['"]\)/);
  assert.match(appSource, /setReasoningExpanded/);
});

test('message toolbar renders bundled Lucide icons instead of text actions', () => {
  assert.match(styleSource, /vendor\/fonts\/lucide\.woff2/);
  assert.match(appSource, /function renderMessageActions/);
  assert.match(appSource, /iconButton\(icon, actionLabel\(action\)/);
  assert.match(appSource, /more:\s*'more'/);
});

test('message surfaces cover Flutter default, frosted, and solid styles', () => {
  assert.match(styleSource, /data-background-style="defaultStyle"/);
  assert.match(styleSource, /data-background-style="frosted"/);
  assert.match(styleSource, /backdrop-filter:\s*blur\(14px\)/);
  assert.match(styleSource, /data-background-style="solid"/);
  assert.match(styleSource, /\.message\.is-user \.bubble\s*\{[^}]*max-width:\s*75%/);
});
