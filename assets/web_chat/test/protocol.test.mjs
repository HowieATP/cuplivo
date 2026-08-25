import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import {
  captureAnchor,
  captureViewport,
  buildWithFrameBudget,
  createAdaptiveStreamPresenter,
  createExpansionCoordinator,
  createFrameCoalescer,
  createVirtualWindowCoordinator,
  createViewportNavigationCoordinator,
  createRenderGate,
  formatReasoningElapsed,
  longestStablePrefix,
  mountCodeBlock,
  messageIndexAtOffset,
  verticalGestureIntent,
  normalizeMeasuredHeight,
  normalizeContentInset,
  rangeChanged,
  receiveTransferChunk,
  reduceEnvelope,
  restoreAnchor,
  restoreViewport,
  safeUtf16SliceEnd,
  virtualCoverage,
  virtualOverscan,
  viewportForSavedAnchor,
  visibleRange,
} from '../protocol.mjs';

const appSource = readFileSync(new URL('../app.mjs', import.meta.url), 'utf8');
const styleSource = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const htmlSource = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const markedSource = readFileSync(new URL('../vendor/marked.min.js', import.meta.url), 'utf8');
const highlightSource = readFileSync(new URL('../vendor/highlight.min.js', import.meta.url), 'utf8');

class TestNode {
  constructor(name) {
    this.name = name;
    this.parent = null;
    this.children = [];
  }

  contains(target) {
    return this === target || this.children.some((child) => child.contains(target));
  }

  append(...nodes) {
    for (const node of nodes) {
      if (node === this || node.contains(this)) throw new Error('HierarchyRequestError');
      node.parent?._remove(node);
      this.children.push(node);
      node.parent = this;
    }
  }

  replaceWith(replacement) {
    const parent = this.parent;
    if (!parent) return;
    if (replacement === parent || replacement.contains(parent)) {
      throw new Error('HierarchyRequestError');
    }
    replacement.parent?._remove(replacement);
    const index = parent.children.indexOf(this);
    parent.children[index] = replacement;
    replacement.parent = parent;
    this.parent = null;
  }

  _remove(node) {
    const index = this.children.indexOf(node);
    if (index >= 0) this.children.splice(index, 1);
    node.parent = null;
  }
}

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
  const current = { type: 'snapshot', protocolVersion: 2, assetVersion: 'web-chat-v12', renderSessionId: 's', renderRevision: 4, messages: [] };
  const older = { ...current, renderRevision: 3, messages: [{ id: 'old' }] };
  assert.equal(reduceEnvelope(current, older), current);
});

test('new snapshots retain resolved opaque media only in the same session', () => {
  const current = {
    type: 'snapshot', protocolVersion: 2, assetVersion: 'web-chat-v12',
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

test('message patches reject stale stream revisions without breaking legacy patches', () => {
  const state = {
    renderSessionId: 's',
    conversationId: 'c',
    messages: [{ id: 'm', content: 'new', isStreaming: true, streamRevision: 4 }],
  };
  const stale = reduceEnvelope(state, {
    type: 'messagePatches',
    renderSessionId: 's',
    conversationId: 'c',
    patches: [{ id: 'm', content: 'old', streamRevision: 3 }],
  });
  assert.equal(stale.messages[0].content, 'new');
  const legacy = reduceEnvelope(state, {
    type: 'messagePatches',
    renderSessionId: 's',
    conversationId: 'c',
    patches: [{ id: 'm', content: 'legacy' }],
  });
  assert.equal(legacy.messages[0].content, 'legacy');
  const finished = {
    ...state,
    messages: [{ id: 'm', content: 'final', isStreaming: false }],
  };
  const late = reduceEnvelope(finished, {
    type: 'messagePatches',
    renderSessionId: 's',
    conversationId: 'c',
    patches: [{ id: 'm', content: 'partial', isStreaming: true, streamRevision: 5 }],
  });
  assert.equal(late.messages[0].content, 'final');
});

test('same-session streaming snapshots preserve a newer live patch', () => {
  const state = {
    type: 'snapshot', protocolVersion: 2, assetVersion: 'web-chat-v12',
    renderSessionId: 's', conversationId: 'c', renderRevision: 2,
    messages: [{ id: 'm', content: 'new', isStreaming: true, streamRevision: 7 }],
  };
  const next = reduceEnvelope(state, {
    ...state,
    renderRevision: 3,
    messages: [{ id: 'm', content: 'old', isStreaming: true }],
  });
  assert.equal(next.messages[0].content, 'new');
  assert.equal(next.messages[0].streamRevision, 7);
});

test('virtual range grows with the viewport rather than total messages', () => {
  const range = visibleRange({ heights: new Array(360).fill(100), scrollTop: 12000, viewportHeight: 700, overscan: 300 });
  assert.ok(range.end - range.start < 20);
  assert.equal(range.top, range.start * 100);
});

test('virtual window uses a bounded three-screen overscan', () => {
  assert.equal(virtualOverscan(700), 2400);
  assert.equal(virtualOverscan(1000), 3000);
  const range = visibleRange({
    heights: new Array(360).fill(100),
    scrollTop: 12000,
    viewportHeight: 700,
    overscan: virtualOverscan(700),
  });
  assert.ok(range.end - range.start < 60);
});

test('virtual coverage clamps an uncovered viewport to rendered messages', () => {
  const heights = new Array(100).fill(100);
  const coverage = virtualCoverage({
    heights,
    range: { start: 20, end: 40 },
    scrollTop: 8200,
    viewportHeight: 700,
  });
  assert.equal(coverage.covered, false);
  assert.equal(coverage.min, 2000);
  assert.equal(coverage.max, 3300);
  assert.equal(coverage.requested, 8200);
  assert.equal(coverage.maxExtent, 9300);
  assert.equal(coverage.clamped, 3300);
  assert.equal(virtualCoverage({
    heights,
    range: { start: 20, end: 40 },
    scrollTop: 2500,
    viewportHeight: 700,
  }).covered, true);
});

test('virtual window paints a loader before rendering and latest target wins', async () => {
  const frames = [];
  const events = [];
  const coordinator = createVirtualWindowCoordinator({
    schedule: (callback) => frames.push(callback),
    setLoading: (value) => events.push(`loading:${value}`),
    clamp: (value) => events.push(`clamp:${value}`),
    renderTarget: async (value) => events.push(`render:${value}`),
    settleTarget: (value) => events.push(`settle:${value}`),
    timeoutMs: 0,
  });
  coordinator.request({ target: 9000, safe: 3300 });
  coordinator.request({ target: 1200, safe: 2000 });
  assert.deepEqual(events, ['loading:true', 'clamp:3300', 'clamp:2000']);
  assert.equal(frames.length, 1);
  frames.shift()(16);
  await Promise.resolve();
  assert.deepEqual(events, [
    'loading:true', 'clamp:3300', 'clamp:2000', 'render:1200',
  ]);
  assert.equal(frames.length, 1);
  frames.shift()(32);
  assert.deepEqual(events, [
    'loading:true', 'clamp:3300', 'clamp:2000', 'render:1200',
    'settle:1200', 'loading:false',
  ]);
});

test('canceling a virtual window prevents stale completion', async () => {
  const frames = [];
  const events = [];
  let finishRender;
  const coordinator = createVirtualWindowCoordinator({
    schedule: (callback) => frames.push(callback),
    setLoading: (value) => events.push(`loading:${value}`),
    clamp: () => {},
    renderTarget: () => new Promise((resolve) => { finishRender = resolve; }),
    settleTarget: () => events.push('settled'),
  });
  coordinator.request({ target: 9000, safe: 3300 });
  frames.shift()(16);
  coordinator.cancel();
  finishRender();
  await Promise.resolve();
  assert.deepEqual(events, ['loading:true', 'loading:false']);
});

test('virtual window timeout stays at the safe boundary and reports failure', async () => {
  const events = [];
  const coordinator = createVirtualWindowCoordinator({
    schedule: (callback) => callback(),
    setLoading: (value) => events.push(`loading:${value}`),
    clamp: (value) => events.push(`clamp:${value}`),
    renderTarget: () => new Promise(() => {}),
    settleTarget: () => events.push('settled'),
    onError: (error) => events.push(error.message),
    timeoutMs: 5,
  });
  coordinator.request({ target: 9000, safe: 3300 });
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.deepEqual(events, [
    'loading:true',
    'clamp:3300',
    'loading:false',
    'virtual_window_timeout',
  ]);
  assert.equal(coordinator.active, false);
});

test('virtual messages build within a per-frame budget and cancel stale work', async () => {
  const frames = [];
  let clock = 0;
  const work = buildWithFrameBudget({
    items: [1, 2, 3, 4, 5],
    schedule: (callback) => frames.push(callback),
    now: () => clock,
    budgetMs: 6,
    build: (value) => {
      clock += 4;
      return value * 2;
    },
  });
  assert.equal(frames.length, 1);
  frames.shift()();
  assert.equal(frames.length, 1);
  frames.shift()();
  assert.equal(frames.length, 1);
  frames.shift()();
  assert.deepEqual(await work, [2, 4, 6, 8, 10]);

  const canceledFrames = [];
  let current = true;
  const canceled = buildWithFrameBudget({
    items: [1, 2],
    schedule: (callback) => canceledFrames.push(callback),
    shouldContinue: () => current,
    build: (value) => value,
  });
  current = false;
  canceledFrames.shift()();
  await assert.rejects(canceled, /virtual_window_stale/);
});

test('adaptive streaming catches up by its deadline and preserves Unicode', () => {
  const frames = [];
  const commits = [];
  let clock = 0;
  const presenter = createAdaptiveStreamPresenter({
    schedule: (callback) => frames.push(callback),
    now: () => clock,
    commit: (id, content) => commits.push([id, content]),
  });
  presenter.update({ id: 'm', displayed: '', target: '你好😀世界' });
  for (const time of [32, 64, 96]) {
    clock = time;
    frames.shift()?.(time);
  }
  assert.equal(commits.at(-1)[1], '你好😀世界');
  for (const [, content] of commits) {
    assert.doesNotMatch(content, /[\uD800-\uDBFF]$/);
  }
});

test('continuous stream updates do not move the original catch-up deadline', () => {
  const frames = [];
  const commits = [];
  let clock = 0;
  const presenter = createAdaptiveStreamPresenter({
    schedule: (callback) => frames.push(callback),
    now: () => clock,
    commit: (_, content) => commits.push(content),
  });
  presenter.update({ id: 'm', target: '第一段较长的初始内容' });
  clock = 20;
  presenter.update({ id: 'm', target: '第一段较长的初始内容和追加内容' });
  clock = 32;
  frames.shift()(clock);
  clock = 48;
  presenter.update({ id: 'm', target: '第一段较长的初始内容和追加内容😀' });
  clock = 64;
  frames.shift()(clock);
  clock = 96;
  frames.shift()?.(clock);
  assert.equal(commits.at(-1), '第一段较长的初始内容和追加内容😀');
});

test('Markdown diff retains the longest unchanged top-level prefix', () => {
  assert.equal(
    longestStablePrefix(
      ['paragraph:first', 'code:stable', 'paragraph:old tail'],
      ['paragraph:first', 'code:stable', 'paragraph:new tail'],
    ),
    2,
  );
  assert.equal(longestStablePrefix(['a'], ['different']), 0);
  assert.equal(longestStablePrefix(null, ['a']), 0);
});

test('streaming rewrites and completion flush immediately', () => {
  const commits = [];
  const presenter = createAdaptiveStreamPresenter({
    schedule: () => {},
    now: () => 0,
    commit: (id, content) => commits.push([id, content]),
  });
  presenter.update({ id: 'm', displayed: 'prefix', target: 'replacement' });
  presenter.update({
    id: 'm', displayed: 'replacement', target: 'replacement final', final: true,
  });
  assert.deepEqual(commits, [
    ['m', 'replacement'],
    ['m', 'replacement final'],
  ]);
  assert.equal(safeUtf16SliceEnd('a😀b', 2), 3);
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

test('render gate defers DOM work throughout a gesture and flushes once', () => {
  let calls = 0;
  const gate = createRenderGate(() => { calls += 1; });
  gate.setBlocked(true);
  assert.equal(gate.blocked, true);
  gate.request();
  gate.request();
  assert.equal(calls, 0);
  assert.equal(gate.pending, true);
  gate.setBlocked(false);
  assert.equal(gate.blocked, false);
  assert.equal(calls, 1);
  assert.equal(gate.pending, false);
  gate.setBlocked(false);
  assert.equal(calls, 1);
});

test('viewport navigation renders the destination before settling and unlocks once', () => {
  const frames = [];
  const events = [];
  let blocked = false;
  let renderPending = false;
  const coordinator = createViewportNavigationCoordinator({
    schedule: (callback) => frames.push(callback),
    setRenderBlocked: (value) => {
      blocked = value;
      events.push(value ? 'block' : 'unblock');
      if (!value && renderPending) {
        renderPending = false;
        frames.push(() => events.push('render'));
      }
    },
    requestRender: () => {
      if (blocked) renderPending = true;
      else frames.push(() => events.push('render'));
    },
    settleFrames: 2,
  });

  coordinator.run(
    () => events.push('settle'),
    () => events.push('complete'),
  );
  assert.equal(blocked, true);
  assert.deepEqual(events, ['block', 'unblock', 'block']);

  frames.shift()();
  frames.shift()();
  assert.deepEqual(events, ['block', 'unblock', 'block', 'render', 'settle']);
  assert.equal(blocked, true);

  frames.shift()();
  assert.equal(blocked, false);
  assert.deepEqual(events, [
    'block', 'unblock', 'block', 'render', 'settle', 'settle', 'unblock',
  ]);

  frames.shift()();
  frames.shift()();
  assert.deepEqual(events, [
    'block', 'unblock', 'block', 'render', 'settle', 'settle', 'unblock',
    'render', 'settle', 'complete',
  ]);
});

test('a newer viewport navigation supersedes stale settling frames', () => {
  const frames = [];
  const settled = [];
  const coordinator = createViewportNavigationCoordinator({
    schedule: (callback) => frames.push(callback),
    setRenderBlocked: () => {},
    requestRender: () => {},
    settleFrames: 1,
  });

  coordinator.run(() => settled.push('old'));
  coordinator.run(() => settled.push('new'));
  while (frames.length) frames.shift()();

  assert.deepEqual(settled, ['new', 'new']);
});

test('canceling an inactive viewport navigation does not release a gesture gate', () => {
  let unlocks = 0;
  const coordinator = createViewportNavigationCoordinator({
    schedule: () => {},
    setRenderBlocked: (value) => {
      if (!value) unlocks += 1;
    },
    requestRender: () => {},
  });

  coordinator.cancel();

  assert.equal(unlocks, 0);
});

test('logical message index resolves when no rendered DOM anchor is available', () => {
  assert.equal(messageIndexAtOffset([100, 120, 140], 0), 0);
  assert.equal(messageIndexAtOffset([100, 120, 140], 99), 0);
  assert.equal(messageIndexAtOffset([100, 120, 140], 100), 1);
  assert.equal(messageIndexAtOffset([100, 120, 140], 999), 2);
  assert.equal(messageIndexAtOffset([], 20), -1);
  assert.equal(messageIndexAtOffset([100, Number.NaN, 140], 150), 1);
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

test('offscreen zero-size observations never replace stable message heights', () => {
  assert.equal(normalizeMeasuredHeight(128.2), 129);
  assert.equal(normalizeMeasuredHeight(0), null);
  assert.equal(normalizeMeasuredHeight(-1), null);
  assert.equal(normalizeMeasuredHeight(Number.NaN), null);
  assert.doesNotMatch(styleSource, /content-visibility:\s*auto/);
});

test('content insets accept finite non-negative values only', () => {
  assert.equal(normalizeContentInset(88), 88);
  assert.equal(normalizeContentInset(-1), 8);
  assert.equal(normalizeContentInset(Number.POSITIVE_INFINITY), 8);
  assert.equal(normalizeContentInset('104'), 8);
  assert.equal(normalizeContentInset(null), 8);
  assert.equal(normalizeContentInset('invalid'), 8);
});

test('reasoning elapsed time mirrors Flutter formatting for live and finished steps', () => {
  const start = '2026-08-25T12:00:00.000Z';
  const finish = '2026-08-25T12:00:01.234Z';
  assert.equal(formatReasoningElapsed(start, finish, false), '(1.2s)');
  assert.equal(formatReasoningElapsed(start, null, true, Date.parse(finish)), '(1.2s)');
  assert.equal(formatReasoningElapsed(start, null, false), '(0.0s)');
  assert.equal(formatReasoningElapsed(null, finish, false), '');
  assert.equal(formatReasoningElapsed('invalid', finish, false), '');
  const replaceIndex = appSource.indexOf('timeline.replaceChildren(fragment)');
  const timerIndex = appSource.indexOf('ensureReasoningElapsedTimer()', replaceIndex);
  assert.ok(replaceIndex >= 0 && timerIndex > replaceIndex);
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
  assert.equal(restoreAnchor(container, anchor), true);
  assert.equal(container.scrollTop, 106);
});

test('virtual rendering keeps the pre-replacement viewport position', () => {
  let nodes = [
    { dataset: { messageId: 'middle' }, getBoundingClientRect: () => ({ top: 10, bottom: 110 }) },
  ];
  const container = {
    scrollTop: 12000,
    scrollHeight: 36000,
    clientHeight: 700,
    getBoundingClientRect: () => ({ top: 0 }),
    querySelectorAll: () => nodes,
  };

  const viewport = captureViewport(container);
  container.scrollTop = 0;
  container.scrollHeight = container.clientHeight;
  nodes = [];

  const range = visibleRange({
    heights: new Array(360).fill(100),
    scrollTop: viewport.scrollTop,
    viewportHeight: viewport.viewportHeight,
    overscan: 300,
  });
  assert.ok(range.start > 0);

  container.scrollHeight = 36000;
  restoreViewport(container, viewport);
  assert.equal(container.scrollTop, 12000);
});

test('viewport restoration prefers anchors and clamps offset fallback', () => {
  const replacement = {
    dataset: { messageId: 'middle' },
    getBoundingClientRect: () => ({ top: 30, bottom: 130 }),
  };
  let nodes = [replacement];
  const container = {
    scrollTop: 0,
    scrollHeight: 900,
    clientHeight: 700,
    getBoundingClientRect: () => ({ top: 10 }),
    querySelectorAll: () => nodes,
  };

  restoreViewport(container, {
    scrollTop: 12000,
    viewportHeight: 700,
    anchor: { id: 'middle', offset: 5 },
  });
  assert.equal(container.scrollTop, 15);

  nodes = [];
  restoreViewport(container, {
    scrollTop: 12000,
    viewportHeight: 700,
    anchor: { id: 'missing', offset: 0 },
  });
  assert.equal(container.scrollTop, 200);
});

test('a new render session starts with a fresh viewport', () => {
  let queried = false;
  const viewport = captureViewport({
    scrollTop: 12000,
    clientHeight: 700,
    querySelectorAll: () => {
      queried = true;
      return [];
    },
  }, { preserve: false });

  assert.deepEqual(viewport, {
    scrollTop: 0,
    viewportHeight: 700,
    anchor: null,
  });
  assert.equal(queried, false);
});

test('a returning conversation seeds its new render session from a message anchor', () => {
  const viewport = viewportForSavedAnchor({
    messageIds: ['m1', 'm2', 'm3', 'm4'],
    heights: [100, 120, 140, 160],
    anchor: { messageId: 'm3', offset: -18 },
    viewportHeight: 700,
  });

  assert.deepEqual(viewport, {
    scrollTop: 238,
    viewportHeight: 700,
    anchor: { id: 'm3', offset: -18 },
  });
  assert.equal(viewportForSavedAnchor({
    messageIds: ['m1'],
    heights: [100],
    anchor: { messageId: 'missing', offset: 0 },
    viewportHeight: 700,
  }), null);
  assert.equal(viewportForSavedAnchor({
    messageIds: ['m1'],
    heights: [100],
    anchor: { messageId: 'm1', offset: Number.NaN },
    viewportHeight: 700,
  }), null);
});

test('mobile shell owns vertical gestures and uses controlled disclosures', () => {
  assert.match(styleSource, /touch-action:\s*pan-y/);
  assert.match(styleSource, /-webkit-overflow-scrolling:\s*touch/);
  assert.doesNotMatch(appSource, /createElement\(['"]details['"]\)/);
  assert.match(appSource, /setReasoningExpanded/);
  assert.match(appSource, /stopScrolling/);
  assert.match(appSource, /pointerdown/);
  assert.match(appSource, /touchstart/);
});

test('pointer down cancels momentum before release while preserving a new drag', () => {
  assert.match(appSource, /let scrollStopLock = false/);
  assert.match(appSource, /function stopScrolling[\s\S]*?scrollStopLock = true/);
  assert.match(appSource, /function releaseScrollStopLock/);
  assert.match(appSource, /scrollStopLock[\s\S]*?requestAnimationFrame/);
  assert.match(appSource, /touchmove[\s\S]*?releaseScrollStopLock\(\)/);
  assert.match(appSource, /touchend[\s\S]*?releaseScrollStopLock\(\)/);
  assert.match(appSource, /touchcancel[\s\S]*?releaseScrollStopLock\(\)/);
  const touchStart = appSource.indexOf("timeline.addEventListener('touchstart'");
  const touchStartBody = appSource.slice(touchStart, touchStart + 500);
  assert.match(touchStartBody, /touchActive = true[\s\S]*?stopScrolling\(\)/);
});

test('touch jitter below the Flutter slop keeps the scroll lock and blocks native drift', () => {
  assert.equal(
    verticalGestureIntent({ startX: 100, startY: 100, currentX: 110, currentY: 110 }),
    'hold',
  );
  assert.equal(
    verticalGestureIntent({ startX: 100, startY: 100, currentX: 100, currentY: 118 }),
    'vertical',
  );
  assert.equal(
    verticalGestureIntent({ startX: 100, startY: 100, currentX: 120, currentY: 101 }),
    'horizontal',
  );
  assert.match(appSource, /let touchStartX = null/);
  assert.match(appSource, /let pointerStartX = null/);
  assert.match(appSource, /verticalGestureIntent\(/);
  assert.match(appSource, /event\.preventDefault\(\)/);
  assert.match(appSource, /touchmove'[\s\S]*?passive: false/);
  assert.match(appSource, /intent === 'hold'[\s\S]*?scrollStopLock/);
  assert.match(appSource, /function stopScrolling[\s\S]*?if \(!scrollStopLock\)/);
  assert.match(appSource, /function restoreScrollStopPosition/);
  assert.match(appSource, /let gestureActive = false/);
  assert.match(appSource, /let gestureIntent = 'idle'/);
  assert.match(appSource, /function stopScrolling[\s\S]*?gestureActive[\s\S]*?gestureIntent/);
  assert.match(appSource, /timeline\.addEventListener\('scroll'[\s\S]*?if \(scrollStopLock\)[\s\S]*?return;/);
});

test('code blocks use the Flutter surface, header, and code-view structure', () => {
  assert.match(appSource, /code-block-header/);
  assert.match(appSource, /code-block-body/);
  assert.match(appSource, /code-block-toggle/);
  assert.match(appSource, /code-block-action/);
  assert.match(appSource, /code-block-pre/);
  assert.match(styleSource, /\.code-block\s*\{/);
  assert.match(styleSource, /\.code-block-header\s*\{/);
  assert.match(styleSource, /\.code-block-body\s*\{/);
  assert.match(styleSource, /\.code-block-pre\s*\{/);
  assert.match(styleSource, /\.code-block-action[\s\S]*?display: grid/);
  assert.match(styleSource, /\.code-block-action[\s\S]*?border: 0/);
  assert.match(styleSource, /code\.hljs\s*\{/);
  assert.match(styleSource, /body\[data-dark="true"\][\s\S]*?\.hljs-keyword/);
  assert.match(styleSource, /font-size:\s*calc\(13px \* var\(--cuplivo-font-scale\)\)/);
  assert.match(styleSource, /\.hljs-deletion[\s\S]*?background: #ffdddd/);
  assert.match(styleSource, /\.hljs-addition[\s\S]*?background: #ddffdd/);
  assert.match(appSource, /function normalizeCodeLanguage/);
  assert.match(appSource, /language: highlightLanguage/);
  assert.match(appSource, /plaintext/);
  assert.match(styleSource, /\.code-block\.is-collapsed/);
  assert.match(appSource, /source\.replace\(\/\(\?:\\r\\n\|\\r\|\\n\)\+\$\//);
});

test('a fenced Python block mounts without creating a DOM ancestry cycle', () => {
  const root = new TestNode('root');
  const pre = new TestNode('pre');
  const block = new TestNode('block');
  const header = new TestNode('header');
  const body = new TestNode('body');
  root.append(pre);

  mountCodeBlock({ pre, block, header, body });

  assert.deepEqual(root.children, [block]);
  assert.deepEqual(block.children, [header, body]);
  assert.deepEqual(body.children, [pre]);
});

test('bundled Markdown and highlighter accept Python f-strings and Unicode', () => {
  const source = 'def greet(name):\n    print(f"Hello, {name}!")\n\ngreet("世界")';
  const fenced = '```python\n' + source + '\n```';
  const sandbox = {};
  vm.createContext(sandbox);
  vm.runInContext(markedSource, sandbox);
  vm.runInContext(highlightSource, sandbox);

  const html = sandbox.marked.parse(fenced);
  assert.match(html, /<pre><code class="language-python">/);
  assert.match(html, /世界/);
  assert.doesNotThrow(() => sandbox.hljs.highlight(source, {
    language: 'python',
    ignoreIllegals: true,
  }));
});

test('virtual DOM replacement captures scroll state first and applies Flutter insets', () => {
  const captureIndex = appSource.indexOf('captureViewport(timeline');
  const themeIndex = appSource.indexOf('applyTheme();', captureIndex);
  const replaceIndex = appSource.indexOf('timeline.replaceChildren(fragment)');
  assert.ok(captureIndex >= 0 && themeIndex > captureIndex && replaceIndex > themeIndex);
  assert.match(appSource, /document\.createDocumentFragment\(\)/);
  assert.match(appSource, /restoreViewport\(timeline, viewport\)/);
  assert.match(styleSource, /overflow-anchor:\s*none/);
  assert.match(styleSource, /padding-block:\s*var\(--cuplivo-content-top-inset\)\s+var\(--cuplivo-content-bottom-inset\)/);
  assert.match(styleSource, /scroll-padding-block:\s*var\(--cuplivo-content-top-inset\)\s+var\(--cuplivo-content-bottom-inset\)/);
});

test('touch and inertial scrolling defer every virtual DOM replacement', () => {
  assert.match(appSource, /touchstart[\s\S]*?setRenderBlocked\(true\)/);
  assert.match(appSource, /function markUserScroll[\s\S]*?setRenderBlocked\(true\)/);
  assert.match(appSource, /messagePatches[\s\S]*?handleMessagePatches\(envelope\)/);
  assert.match(appSource, /function updateMountedStreamingContent/);
  assert.match(appSource, /patchStreamingMarkdownRoot/);
  assert.match(appSource, /function handleMediaResult/);
  assert.doesNotMatch(appSource, /payload\.type === 'mediaResult'[\s\S]{0,300}requestRender\(\)/);
  assert.doesNotMatch(appSource, /messagePatches[^\n]*scheduleRender\(\)/);
  assert.match(appSource, /function handleMeasuredHeights[\s\S]*?measuredHeightsPending = true/);
  assert.match(appSource, /createFrameCoalescer\(\s*reconcileMeasuredHeights/);
  const measureStart = appSource.indexOf('function handleMeasuredHeights');
  const measureEnd = appSource.indexOf('function reconcileMeasuredHeights', measureStart);
  assert.doesNotMatch(appSource.slice(measureStart, measureEnd), /requestRender\(\)/);
});

test('virtual boundaries show a localized loader and use budgeted detached work', () => {
  assert.match(htmlSource, /id="virtual-window-loader"/);
  assert.match(htmlSource, /id="virtual-window-loader-label"/);
  assert.match(styleSource, /#virtual-window-loader\s*\{/);
  assert.match(appSource, /setVirtualWindowLoading/);
  assert.match(appSource, /buildWithFrameBudget/);
  assert.match(appSource, /coverage\.requested/);
  assert.match(appSource, /virtual_window_timeout/);
});

test('stream patches avoid DOM work for offscreen messages and retain stable blocks', () => {
  const handlerStart = appSource.indexOf('function handleMessagePatches');
  const handlerEnd = appSource.indexOf('function handleMediaResult', handlerStart);
  const handler = appSource.slice(handlerStart, handlerEnd);
  const offscreen = handler.indexOf('!mountedSlots.get(id)?.isConnected');
  const offscreenContinue = handler.indexOf('continue;', offscreen);
  const mountedUpdate = handler.indexOf('updateMountedMessage(id)', offscreen);
  assert.ok(offscreen >= 0 && offscreenContinue > offscreen);
  assert.ok(mountedUpdate > offscreenContinue);
  assert.match(appSource, /longestStablePrefix\(previous\?\.signatures, signatures\)/);
  assert.match(appSource, /streamingMarkdownStates\.set/);
});

test('viewport commands use an atomic render-and-settle transaction', () => {
  const commandStart = appSource.indexOf('function handleViewportCommand');
  const commandBody = appSource.slice(commandStart, commandStart + 2200);
  const prepareIndex = commandBody.indexOf('prepareProgrammaticNavigation()');
  const topIndex = commandBody.indexOf("command === 'top'");
  assert.ok(prepareIndex >= 0 && topIndex > prepareIndex);
  assert.match(appSource, /function prepareProgrammaticNavigation[\s\S]*?releaseScrollStopLock\(\)/);
  assert.match(appSource, /function prepareProgrammaticNavigation[\s\S]*?userScrolling = false/);
  assert.match(appSource, /createViewportNavigationCoordinator\(\{[\s\S]*?setRenderBlocked[\s\S]*?requestRender/);
  assert.match(appSource, /function navigateToEdge[\s\S]*?viewportNavigation\.run/);
  assert.match(appSource, /function navigateToEdge[\s\S]*?navigationEdge = edge/);
  assert.match(appSource, /function navigateToEdge[\s\S]*?beginVirtualWindowLoad/);
  assert.match(appSource, /function handleMeasuredHeights[\s\S]*?enforceNavigationEdge\(\)/);
  assert.match(appSource, /function scrollToMessage[\s\S]*?viewportNavigation\.run/);
  assert.match(appSource, /function scrollToMessage[\s\S]*?beginVirtualWindowLoad/);
  assert.doesNotMatch(commandBody, /behavior:\s*'smooth'/);
  assert.match(appSource, /type: 'viewportMetrics'[\s\S]*?conversationId: renderedConversationId/);
  assert.match(appSource, /const missingSavedAnchor[\s\S]*?messages\.reduce\(\(sum, message\)/);
  assert.doesNotMatch(appSource, /filter\(\(message\) => message\.role === 'user'\)/);
  assert.match(appSource, /messageIndexAtOffset\(messages\.map\(messageHeight\), timeline\.scrollTop\)/);
});

test('assistant background uses a dedicated fixed layer and Flutter mask gradient', () => {
  assert.match(htmlSource, /id="chat-background"/);
  assert.match(appSource, /const backgroundLayer = document\.getElementById\('chat-background'\)/);
  assert.match(appSource, /backgroundLayer\.style\.backgroundImage/);
  assert.match(styleSource, /#chat-background\s*\{[^}]*position:\s*fixed/);
  assert.match(styleSource, /#chat-background::after\s*\{[^}]*rgba\(0,\s*0,\s*0,\s*\.04\)/);
  assert.match(styleSource, /linear-gradient\([^;]*--cuplivo-background-mask-top[^;]*--cuplivo-background-mask-bottom/);
  assert.match(appSource, /backgroundOwner/);
  assert.match(styleSource, /data-background-owner="flutter"/);
});

test('message composition follows Flutter visual grouping', () => {
  assert.match(appSource, /assistant-text-surface/);
  assert.match(appSource, /chain-card/);
  assert.match(appSource, /attachments/);
  assert.match(appSource, /renderSuggestions/);
  assert.doesNotMatch(appSource, /fragment\.append\(suggestions\)/);
  const messageIndex = appSource.indexOf('slot.append(renderMessage');
  const dividerIndex = appSource.indexOf('slot.append(divider)', messageIndex);
  assert.ok(messageIndex >= 0 && dividerIndex > messageIndex);
  assert.match(styleSource, /\.assistant-text-surface/);
  assert.match(styleSource, /\.chain-card/);
  assert.match(styleSource, /\.attachments/);
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
