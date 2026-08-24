import {
  ASSET_VERSION,
  PROTOCOL_VERSION,
  captureAnchor,
  createFrameCoalescer,
  receiveTransferChunk,
  reduceEnvelope,
  restoreAnchor,
  visibleRange,
} from './protocol.mjs';

const timeline = document.getElementById('timeline');
let state = null;
let requestSequence = 0;
const heights = new Map();
const pendingActions = new Map();
const pendingMedia = new Set();
let resizeObserver = null;
let userScrolling = false;
let userScrollTimer = null;
let renderedRange = { start: -1, end: -1 };

const bridge = {
  post(message) {
    const encoded = JSON.stringify(message);
    if (window.chrome?.webview) window.chrome.webview.postMessage(encoded);
    else window.CuplivoChat?.postMessage(encoded);
  },
};

function t(key) { return state?.strings?.[key] ?? ''; }
function messageHeight(message) { return heights.get(message.id) ?? 170; }
function applyTheme() {
  if (!state) return;
  for (const [name, value] of Object.entries(state.theme ?? {})) {
    document.documentElement.style.setProperty(`--cuplivo-${name}`, value);
  }
  document.documentElement.style.setProperty('--cuplivo-font-scale', String(state.fontScale ?? 1));
  timeline.setAttribute('aria-label', t('timeline'));
  const background = state.assistant?.background;
  const source = state.media?.[background] ?? background ?? '';
  document.body.style.backgroundColor = source.startsWith('#') ? source : 'transparent';
  document.body.style.backgroundImage = /^(data:|https?:)/.test(source) ? `url("${source.replaceAll('"', '%22')}")` : 'none';
  document.body.style.backgroundSize = 'cover';
  document.body.style.backgroundPosition = 'center';
  if (background?.startsWith('local:') && !state.media?.[background]) requestMedia(background);
}

function sendAction(action, messageId = null, payload = {}) {
  if (!state) return;
  if ((action === 'loadMoreBefore' || action === 'loadMoreAfter') &&
      [...pendingActions.values()].includes(action)) return;
  const requestId = `${state.renderSessionId}:${Date.now()}:${requestSequence += 1}`;
  pendingActions.set(requestId, action);
  bridge.post({
    type: 'action', requestId, action, messageId, payload,
    protocolVersion: PROTOCOL_VERSION,
    renderSessionId: state.renderSessionId,
    conversationId: state.conversationId,
    actionEpoch: state.actionEpoch,
    capabilityToken: state.capabilityToken,
  });
}

function requestMedia(handle) {
  if (!state || !handle?.startsWith('local:') || pendingMedia.has(handle)) return;
  pendingMedia.add(handle);
  bridge.post({
    type: 'mediaRequest', handle,
    renderSessionId: state.renderSessionId,
    conversationId: state.conversationId,
    capabilityToken: state.capabilityToken,
  });
}

function actionLabel(action) {
  return t({
    copy: 'copy', edit: 'edit', resend: 'resend', regenerate: 'regenerate',
    quote: 'quote', translate: 'translate', speak: 'speak', share: 'share',
    fork: 'fork', select: 'select', delete: 'delete', multiAI: 'multiAI',
  }[action]);
}

function button(label, onClick, className = 'action') {
  const node = document.createElement('button');
  node.type = 'button';
  node.className = className;
  node.textContent = label;
  node.setAttribute('aria-label', label);
  node.addEventListener('click', onClick);
  return node;
}

function markdownNode(content, streaming = false, kind = 'assistant') {
  const root = document.createElement('div');
  root.className = 'markdown';
  const markdownEnabled = kind === 'user' ? state.display?.userMarkdown !== false :
    kind === 'reasoning' ? state.display?.reasoningMarkdown !== false :
    state.display?.assistantMarkdown !== false;
  if (!markdownEnabled) {
    root.textContent = content ?? '';
    root.style.whiteSpace = 'pre-wrap';
    return root;
  }
  try {
    const html = window.marked.parse(content ?? '', { gfm: true, breaks: true });
    root.innerHTML = window.DOMPurify.sanitize(html, {
      USE_PROFILES: { html: true, svg: true, svgFilters: true },
      ADD_ATTR: ['target', 'rel', 'referrerpolicy'],
      FORBID_TAGS: ['style', 'form', 'object', 'iframe', 'script'],
      FORBID_ATTR: ['style', 'srcset'],
    });
    enhanceMarkdown(root, streaming);
  } catch (error) {
    bridge.post({ type: 'diagnostic', code: 'markdown_block_failed' });
    root.className = 'block-error';
    root.textContent = t('unsupportedBlock');
  }
  return root;
}

function enhanceMarkdown(root, streaming) {
  for (const link of root.querySelectorAll('a[href]')) {
    const href = link.getAttribute('href');
    link.removeAttribute('href');
    link.setAttribute('role', 'link');
    link.tabIndex = 0;
    const open = (event) => {
      event.preventDefault();
      bridge.post({
        type: 'externalLink',
        url: href,
        renderSessionId: state.renderSessionId,
        conversationId: state.conversationId,
        capabilityToken: state.capabilityToken,
      });
    };
    link.addEventListener('click', open);
    link.addEventListener('keydown', (event) => { if (event.key === 'Enter') open(event); });
  }
  for (const image of root.querySelectorAll('img')) image.referrerPolicy = 'no-referrer';
  for (const code of root.querySelectorAll('pre > code')) {
    const language = [...code.classList].find((name) => name.startsWith('language-'))?.slice(9) ?? '';
    if (language === 'mermaid' && !streaming) {
      renderMermaid(code.parentElement, code.textContent ?? '');
      continue;
    }
    if (language === 'html' && !streaming) addHtmlPreview(code.parentElement, code.textContent ?? '');
    try { window.hljs.highlightElement(code); }
    catch { bridge.post({ type: 'diagnostic', code: 'highlight_block_failed' }); }
    const copy = button(t('copyCode'), () => {
      sendAction('copyText', null, { text: code.textContent ?? '' });
    });
    code.parentElement.prepend(copy);
    if (state.display?.wrapCode === true) code.style.whiteSpace = 'pre-wrap';
    const threshold = Number(state.display?.collapsedCodeLines ?? 0);
    const lineCount = (code.textContent?.match(/\n/g)?.length ?? 0) + 1;
    if (threshold > 0 && lineCount > threshold) {
      const pre = code.parentElement;
      pre.classList.add('code-collapsed');
      pre.style.setProperty('--collapsed-lines', String(threshold));
      const toggle = button(t('expandCode'), () => {
        const collapsed = pre.classList.toggle('code-collapsed');
        toggle.textContent = collapsed ? t('expandCode') : t('collapseCode');
        toggle.setAttribute('aria-label', toggle.textContent);
      });
      pre.prepend(toggle);
    }
  }
  try {
    if (state.display?.math === false) return;
    window.renderMathInElement(root, {
      throwOnError: false,
      delimiters: [
        { left: '$$', right: '$$', display: true },
        ...(state.display?.dollarMath === true ? [{ left: '$', right: '$', display: false }] : []),
        { left: '\\[', right: '\\]', display: true },
        { left: '\\(', right: '\\)', display: false },
      ],
    });
  } catch { bridge.post({ type: 'diagnostic', code: 'math_block_failed' }); }
}

async function renderMermaid(pre, source) {
  try {
    window.mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: 'default' });
    const { svg } = await window.mermaid.render(`m-${Date.now()}-${requestSequence += 1}`, source);
    if (!pre.isConnected) return;
    const wrapper = document.createElement('div');
    wrapper.innerHTML = window.DOMPurify.sanitize(svg, {
      USE_PROFILES: { svg: true, svgFilters: true },
      FORBID_TAGS: ['style', 'foreignObject', 'script'],
    });
    pre.replaceWith(wrapper);
  } catch {
    bridge.post({ type: 'diagnostic', code: 'mermaid_block_failed' });
    pre.className = 'block-error';
    pre.textContent = t('unsupportedBlock');
  }
}

function addHtmlPreview(pre, source) {
  const details = document.createElement('details');
  const summary = document.createElement('summary');
  summary.textContent = t('htmlPreview');
  const frame = document.createElement('iframe');
  frame.setAttribute('sandbox', 'allow-scripts');
  frame.referrerPolicy = 'no-referrer';
  frame.srcdoc = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:">${source}`;
  details.append(summary, frame);
  pre.after(details);
}

function renderReasoning(message, parent) {
  const segments = message.reasoning?.length ? message.reasoning :
    (message.legacyThinking ?? []).map((text) => ({ text, expanded: false, loading: false }));
  for (const [index, segment] of segments.entries()) renderReasoningSegment(message, segment, index, parent);
}

function renderReasoningSegment(message, segment, index, parent) {
    const details = document.createElement('details');
    details.className = 'thinking';
    details.dataset.component = 'reasoning';
    details.open = Boolean(segment.expanded);
    const summary = document.createElement('summary');
    summary.textContent = segment.loading ? t('thinking') : t('reasoning');
    const body = document.createElement('div');
    body.className = 'thinking-body';
    body.append(markdownNode(segment.text ?? '', Boolean(segment.loading), 'reasoning'));
    details.addEventListener('toggle', () => sendAction('toggleReasoningSegment', message.id, { index, expanded: details.open }));
    details.append(summary, body);
    parent.append(details);
}

function renderConversationBlocks(message, parent) {
  const reasoning = message.reasoning?.length ? message.reasoning :
    (message.legacyThinking ?? []).map((text) => ({ text, expanded: false, loading: false }));
  const tools = message.tools ?? [];
  const splits = message.contentSplits ?? {};
  const offsets = splits.offsets ?? [];
  const reasoningCounts = splits.reasoningCounts ?? [];
  const toolCounts = splits.toolCounts ?? [];
  if (!offsets.length) {
    renderReasoning(message, parent);
    parent.append(markdownNode(message.content, message.isStreaming, message.role));
    for (const tool of tools) renderTool(message, tool, parent);
    return;
  }
  let contentOffset = 0;
  let reasoningIndex = 0;
  let toolIndex = 0;
  for (let index = 0; index < offsets.length; index += 1) {
    const offset = Math.max(contentOffset, Math.min(message.content.length, offsets[index]));
    if (offset > contentOffset) parent.append(markdownNode(message.content.slice(contentOffset, offset), message.isStreaming, message.role));
    while (reasoningIndex < Math.min(reasoning.length, reasoningCounts[index] ?? 0)) {
      renderReasoningSegment(message, reasoning[reasoningIndex], reasoningIndex, parent);
      reasoningIndex += 1;
    }
    while (toolIndex < Math.min(tools.length, toolCounts[index] ?? 0)) {
      renderTool(message, tools[toolIndex], parent);
      toolIndex += 1;
    }
    contentOffset = offset;
  }
  while (reasoningIndex < reasoning.length) {
    renderReasoningSegment(message, reasoning[reasoningIndex], reasoningIndex, parent);
    reasoningIndex += 1;
  }
  while (toolIndex < tools.length) {
    renderTool(message, tools[toolIndex], parent);
    toolIndex += 1;
  }
  if (contentOffset < message.content.length) parent.append(markdownNode(message.content.slice(contentOffset), message.isStreaming, message.role));
}

function renderTool(message, tool, parent) {
  const details = document.createElement('details');
  details.className = 'tool';
  details.dataset.component = 'tool';
  const summary = document.createElement('summary');
  summary.textContent = `${tool.content == null ? t('toolCall') : t('toolResult')} ${tool.toolName}`.trim();
  const body = document.createElement('div');
  body.className = 'tool-body';
  const args = document.createElement('pre');
  args.textContent = JSON.stringify(tool.arguments ?? {}, null, 2);
  body.append(args);
  if (tool.content != null) body.append(markdownNode(tool.content, tool.loading));
  if (tool.arguments?.approvalRequired === true && tool.content == null) {
    const actions = document.createElement('div');
    actions.className = 'tool-actions';
    actions.append(
      button(t('approve'), () => sendAction('approveTool', message.id, { toolId: tool.id })),
      button(t('deny'), () => sendAction('denyTool', message.id, { toolId: tool.id })),
    );
    body.append(actions);
  }
  if (tool.arguments?.askUserActive === true && tool.content == null) renderAskUser(message, tool, body);
  details.append(summary, body);
  parent.append(details);
}

function renderAskUser(message, tool, parent) {
  const form = document.createElement('form');
  const questions = tool.arguments?.questions ?? [];
  const skipped = new Set();
  const customNames = new Map();
  for (const [index, question] of questions.entries()) {
    const fieldset = document.createElement('fieldset');
    const legend = document.createElement('legend');
    legend.textContent = question.question ?? '';
    fieldset.append(legend);
    const name = question.id ?? `q${index + 1}`;
    if (question.options?.length) {
      for (const option of question.options) {
        const label = document.createElement('label');
        const input = document.createElement('input');
        input.type = question.type === 'multi' ? 'checkbox' : 'radio';
        input.name = name;
        input.value = option;
        if (input.type === 'radio') input.required = true;
        label.append(input, document.createTextNode(option));
        fieldset.append(label);
      }
    }
    const custom = document.createElement('input');
    custom.name = `${name}__custom`;
    custom.placeholder = t('customAnswer');
    customNames.set(name, custom.name);
    if (!question.options?.length) custom.required = true;
    fieldset.append(custom);
    const skip = button(t('skip'), () => {
      const isSkipped = !skipped.has(name);
      if (isSkipped) skipped.add(name); else skipped.delete(name);
      for (const input of fieldset.querySelectorAll('input')) input.disabled = isSkipped;
      skip.textContent = isSkipped ? t('skipped') : t('skip');
      skip.setAttribute('aria-label', skip.textContent);
    });
    fieldset.append(skip);
    form.append(fieldset);
  }
  const submit = button(t('submit'), () => {}, 'action');
  submit.type = 'submit';
  form.append(submit);
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const data = new FormData(form);
    const custom = [];
    const answers = Object.fromEntries(questions.map((question, index) => {
      const name = question.id ?? `q${index + 1}`;
      const values = data.getAll(name).map(String);
      const customValue = String(data.get(customNames.get(name)) ?? '').trim();
      if (customValue) {
        custom.push(name);
        if (question.type === 'single') values.splice(0, values.length, customValue);
        else values.push(customValue);
      }
      return [name, values];
    }));
    sendAction('answerTool', message.id, {
      toolId: tool.id,
      answers,
      skipped: [...skipped],
      custom,
    });
  });
  parent.append(form);
}

function renderAttachments(message, parent) {
  for (const attachment of message.attachments ?? []) {
    const source = state.media?.[attachment.reference] ?? attachment.reference;
    if (attachment.kind === 'image' && /^(data:|https?:)/.test(source)) {
      const image = document.createElement('img');
      image.dataset.component = 'attachment-image';
      image.src = source;
      image.alt = attachment.name ?? '';
      image.referrerPolicy = 'no-referrer';
      parent.append(image);
    } else if (attachment.kind === 'image' && attachment.reference?.startsWith('local:')) {
      requestMedia(attachment.reference);
    } else if (attachment.kind === 'file') {
      const file = document.createElement('div');
      file.className = 'tool-body';
      file.dataset.component = 'attachment-file';
      file.textContent = attachment.name ?? attachment.mime ?? '';
      parent.append(file);
    }
  }
}

function renderMessage(message) {
  const article = document.createElement('article');
  article.className = 'message';
  article.dataset.component = 'message';
  article.dataset.role = message.role;
  article.dataset.selected = String(Boolean(message.selected));
  article.tabIndex = -1;

  const avatar = document.createElement('div');
  avatar.className = 'avatar';
  const assistant = state.assistant ?? {};
  const avatarSource = state.media?.[assistant.avatar] ?? assistant.avatar ?? '';
  if (message.role !== 'user' && assistant.useAvatar && /^(data:|https?:)/.test(avatarSource)) {
    const image = document.createElement('img');
    image.src = avatarSource;
    image.alt = assistant.name ?? '';
    image.referrerPolicy = 'no-referrer';
    avatar.append(image);
  } else {
    if (message.role !== 'user' && assistant.useAvatar && assistant.avatar?.startsWith('local:')) requestMedia(assistant.avatar);
    avatar.textContent = message.role === 'user' ? t('userInitial') : (assistant.avatarLabel?.[0] ?? assistant.name?.[0] ?? t('assistantInitial'));
  }

  const main = document.createElement('div');
  main.className = 'message-main';
  const meta = document.createElement('div');
  meta.className = 'meta';
  const name = document.createElement('span');
  name.className = 'name';
  name.textContent = message.role === 'user' ? t('user') : (assistant.useName ? assistant.name : (message.modelId ?? assistant.name ?? t('assistant')));
  const time = document.createElement('time');
  time.dateTime = message.timestamp;
  time.textContent = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit' }).format(new Date(message.timestamp));
  meta.append(name, time);
  if (message.tokens != null) {
    const tokens = document.createElement('span');
    tokens.textContent = `${message.tokens} ${t('tokens')}`;
    meta.append(tokens);
  }

  const bubble = document.createElement('div');
  bubble.className = 'bubble';
  bubble.dataset.component = 'message-bubble';
  renderConversationBlocks(message, bubble);
  renderAttachments(message, bubble);
  if (message.translation) {
    const translation = document.createElement('details');
    translation.open = true;
    const summary = document.createElement('summary');
    summary.textContent = t('translation');
    translation.append(summary, markdownNode(message.translation, message.isStreaming));
    bubble.append(translation);
  }

  const actions = document.createElement('div');
  actions.className = 'actions';
  actions.dataset.component = 'message-actions';
  for (const action of message.actions ?? []) {
    actions.append(button(actionLabel(action), () => sendAction(action, message.id)));
  }
  if ((message.versionCount ?? 1) > 1) {
    actions.append(
      button(t('previousVersion'), () => sendAction('version', message.id, { delta: -1 })),
      button(t('nextVersion'), () => sendAction('version', message.id, { delta: 1 })),
    );
  }
  main.append(meta, bubble, actions);
  article.append(avatar, main);
  article.addEventListener('contextmenu', (event) => { event.preventDefault(); actions.firstElementChild?.focus(); });
  return article;
}

function render() {
  if (!state) return;
  const anchor = captureAnchor(timeline);
  resizeObserver?.disconnect();
  resizeObserver = new ResizeObserver((entries) => {
    let changed = false;
    for (const entry of entries) {
      const id = entry.target.dataset.messageId;
      const height = Math.ceil(entry.borderBoxSize?.[0]?.blockSize ?? entry.contentRect.height);
      if (id && Math.abs((heights.get(id) ?? 0) - height) > 1) { heights.set(id, height); changed = true; }
    }
    if (changed) scheduleRender();
  });
  const messages = state.messages ?? [];
  timeline.replaceChildren();
  if (messages.length === 0) {
    renderedRange = { start: 0, end: 0 };
    const empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = t('empty');
    timeline.append(empty);
    return;
  }
  const range = visibleRange({ heights: messages.map(messageHeight), scrollTop: timeline.scrollTop, viewportHeight: timeline.clientHeight });
  renderedRange = { start: range.start, end: range.end };
  const top = document.createElement('div'); top.className = 'spacer'; top.style.height = `${range.top}px`;
  const bottom = document.createElement('div'); bottom.className = 'spacer'; bottom.style.height = `${range.bottom}px`;
  timeline.append(top);
  if (state.preset) {
    const preset = document.createElement('div');
    preset.className = 'suggestions';
    preset.append(button(state.preset.label, () => sendAction('togglePresets'), 'suggestion'));
    timeline.append(preset);
  }
  for (const message of messages.slice(range.start, range.end)) {
    const slot = document.createElement('div');
    slot.className = 'message-slot';
    slot.dataset.messageId = message.id;
    if (message.showContextDivider) {
      const divider = document.createElement('div');
      divider.className = 'context-divider';
      divider.textContent = t('contextDivider');
      slot.append(divider);
    }
    const node = renderMessage(message); slot.append(node); timeline.append(slot); resizeObserver.observe(slot);
  }
  timeline.append(bottom);
  if (state.suggestions?.length) {
    const suggestions = document.createElement('div'); suggestions.className = 'suggestions';
    for (const suggestion of state.suggestions) suggestions.append(button(suggestion, () => sendAction('suggestion', null, { text: suggestion }), 'suggestion'));
    timeline.append(suggestions);
  }
  const nav = document.createElement('nav'); nav.className = 'nav';
  nav.append(
    button(t('top'), () => timeline.scrollTo({ top: 0, behavior: 'smooth' })),
    button(t('bottom'), () => timeline.scrollTo({ top: timeline.scrollHeight, behavior: 'smooth' })),
  );
  timeline.append(nav);
  restoreAnchor(timeline, anchor);
}

const scheduleRender = createFrameCoalescer(render);
const sendViewportMetrics = createFrameCoalescer(() => {
  const anchor = captureAnchor(timeline);
  bridge.post({
    type: 'viewportMetrics',
    pixels: timeline.scrollTop,
    maxExtent: Math.max(0, timeline.scrollHeight - timeline.clientHeight),
    isUserScrolling: userScrolling,
    anchorMessageId: anchor?.id ?? null,
    anchorOffset: anchor?.offset ?? 0,
  });
});
function markUserScroll() {
  userScrolling = true;
  clearTimeout(userScrollTimer);
  userScrollTimer = setTimeout(() => { userScrolling = false; sendViewportMetrics(); }, 800);
}
timeline.addEventListener('wheel', markUserScroll, { passive: true });
timeline.addEventListener('pointerdown', markUserScroll, { passive: true });
timeline.addEventListener('scroll', () => {
  if (state?.messages?.length) {
    const range = visibleRange({
      heights: state.messages.map(messageHeight),
      scrollTop: timeline.scrollTop,
      viewportHeight: timeline.clientHeight,
    });
    if (range.start !== renderedRange.start || range.end !== renderedRange.end) scheduleRender();
  }
  sendViewportMetrics();
  if (timeline.scrollTop < 180 && state?.hasMoreBefore) sendAction('loadMoreBefore');
  if (timeline.scrollHeight - timeline.scrollTop - timeline.clientHeight < 180 && state?.hasMoreAfter) sendAction('loadMoreAfter');
}, { passive: true });
timeline.addEventListener('keydown', (event) => {
  if (event.key === 'Home') timeline.scrollTo({ top: 0, behavior: 'smooth' });
  else if (event.key === 'End') timeline.scrollTo({ top: timeline.scrollHeight, behavior: 'smooth' });
  else if (event.key === 'PageUp') timeline.scrollBy({ top: -timeline.clientHeight * .85, behavior: 'smooth' });
  else if (event.key === 'PageDown') timeline.scrollBy({ top: timeline.clientHeight * .85, behavior: 'smooth' });
});
window.addEventListener('resize', scheduleRender);

function handleViewportCommand(envelope) {
  const command = envelope.command;
  const payload = envelope.payload ?? {};
  const behavior = payload.animate === false ? 'auto' : 'smooth';
  if (command === 'top') timeline.scrollTo({ top: 0, behavior });
  else if (command === 'bottom') timeline.scrollTo({ top: timeline.scrollHeight, behavior });
  else if (command === 'message') scrollToMessage(payload.messageId, behavior);
  else if (command === 'previousQuestion') jumpQuestion(-1);
  else if (command === 'nextQuestion') jumpQuestion(1);
  else if (command === 'restoreAnchor') {
    scheduleRender();
    requestAnimationFrame(() => restoreAnchor(timeline, { id: payload.messageId, offset: payload.offset ?? 0 }));
  }
}

function scrollToMessage(messageId, behavior = 'smooth') {
  const index = state?.messages?.findIndex((message) => message.id === messageId) ?? -1;
  if (index < 0) return;
  const top = state.messages.slice(0, index).reduce((sum, message) => sum + messageHeight(message), 0);
  timeline.scrollTo({ top, behavior });
  scheduleRender();
  requestAnimationFrame(() => timeline.querySelector(`[data-message-id="${CSS.escape(messageId)}"]`)?.focus({ preventScroll: true }));
}

function jumpQuestion(delta) {
  const questions = (state?.messages ?? []).filter((message) => message.role === 'user');
  if (!questions.length) return;
  const anchor = captureAnchor(timeline);
  let index = questions.findIndex((message) => message.id === anchor?.id);
  if (index < 0) index = delta > 0 ? -1 : questions.length;
  const next = Math.max(0, Math.min(questions.length - 1, index + delta));
  scrollToMessage(questions[next].id);
}

window.CuplivoWeb = {
  receive(raw) {
    try {
      const envelope = typeof raw === 'string' ? JSON.parse(raw) : raw;
      if (envelope.type === 'transferChunk') {
        const payload = receiveTransferChunk(envelope);
        if (!payload) return;
        if (payload.type === 'mediaResult') {
          if (state && payload.renderSessionId === state.renderSessionId && payload.conversationId === state.conversationId) {
            state = { ...state, media: { ...(state.media ?? {}), [payload.handle]: payload.dataUrl } };
            pendingMedia.delete(payload.handle);
            scheduleRender();
          }
        } else {
          state = reduceEnvelope(state, payload);
          applyTheme(); scheduleRender();
        }
      } else if (envelope.type === 'messagePatches') {
        state = reduceEnvelope(state, envelope); scheduleRender();
      } else if (envelope.type === 'actionResult') pendingActions.delete(envelope.requestId);
      else if (envelope.type === 'mediaError') pendingMedia.delete(envelope.handle);
      else if (envelope.type === 'viewportCommand') handleViewportCommand(envelope);
    } catch (error) {
      bridge.post({ type: 'diagnostic', code: error?.message ?? 'receive_failed' });
    }
  },
};
window.chrome?.webview?.addEventListener('message', (event) => window.CuplivoWeb.receive(event.data));
bridge.post({ type: 'ready', protocolVersion: PROTOCOL_VERSION, assetVersion: ASSET_VERSION });
