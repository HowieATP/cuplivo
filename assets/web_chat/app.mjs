import {
  ASSET_VERSION,
  PROTOCOL_VERSION,
  captureAnchor,
  captureViewport,
  createExpansionCoordinator,
  createFrameCoalescer,
  createRenderGate,
  formatReasoningElapsed,
  mountCodeBlock,
  normalizeMeasuredHeight,
  normalizeContentInset,
  rangeChanged,
  receiveTransferChunk,
  reduceEnvelope,
  restoreAnchor,
  restoreViewport,
  viewportForSavedAnchor,
  verticalGestureIntent,
  visibleRange,
} from './protocol.mjs';

const timeline = document.getElementById('timeline');
const backgroundLayer = document.getElementById('chat-background');
let state = null;
let requestSequence = 0;
const heights = new Map();
const pendingActions = new Map();
const pendingMedia = new Set();
const localExpansions = new Map();
const expansionCoordinator = createExpansionCoordinator();
const disclosureAnimations = new WeakMap();
let resizeObserver = null;
let userScrolling = false;
let userScrollTimer = null;
let renderedRange = { start: -1, end: -1 };
let topSpacer = null;
let bottomSpacer = null;
let touchStartX = null;
let touchStartY = null;
let touchActive = false;
let pointerStartX = null;
let pointerStartY = null;
let scrollStopLock = false;
let scrollStopFrame = 0;
let scrollStopTop = 0;
let scrollStopLeft = 0;
let gestureActive = false;
let gestureIntent = 'idle';
let renderedSessionId = null;
let renderedConversationId = null;
let reasoningElapsedTimer = null;

const bridge = {
  post(message) {
    const encoded = JSON.stringify(message);
    if (window.chrome?.webview) window.chrome.webview.postMessage(encoded);
    else window.CuplivoChat?.postMessage(encoded);
  },
};

function t(key) { return state?.strings?.[key] ?? ''; }
function messageHeight(message) { return heights.get(message.id) ?? 170; }
function virtualOverscan(viewportHeight) {
  return Math.max(6000, Number(viewportHeight) * 8 || 0);
}
function isMediaHandle(value) {
  return value?.startsWith('local:') || value?.startsWith('asset:');
}
function applyTheme() {
  if (!state) return;
  for (const [name, value] of Object.entries(state.theme ?? {})) {
    document.documentElement.style.setProperty(`--cuplivo-${name}`, value);
  }
  document.documentElement.style.setProperty('--cuplivo-font-scale', String(state.fontScale ?? 1));
  const insets = state.display?.contentInsets ?? {};
  document.documentElement.style.setProperty(
    '--cuplivo-content-top-inset',
    `${normalizeContentInset(insets.top)}px`,
  );
  document.documentElement.style.setProperty(
    '--cuplivo-content-bottom-inset',
    `${normalizeContentInset(insets.bottom)}px`,
  );
  document.body.dataset.backgroundStyle = state.display?.backgroundStyle ?? 'defaultStyle';
  document.body.dataset.dark = String(Boolean(state.display?.isDark));
  const backgroundOwner = state.display?.backgroundOwner === 'flutter'
    ? 'flutter'
    : 'web';
  document.body.dataset.backgroundOwner = backgroundOwner;
  timeline.setAttribute('aria-label', t('timeline'));
  const background = state.assistant?.background;
  const source = state.media?.[background] ?? background ?? '';
  const isColor = source.startsWith('#');
  const isImage = /^(data:|https?:)/.test(source);
  if (backgroundOwner === 'web') {
    backgroundLayer.style.backgroundColor = isColor ? source : 'transparent';
    backgroundLayer.style.backgroundImage = isImage
      ? `url("${source.replaceAll('"', '%22')}")`
      : 'none';
    document.body.dataset.hasBackground = String(isColor || isImage);
    if (isMediaHandle(background) && !state.media?.[background]) requestMedia(background);
  } else {
    backgroundLayer.style.backgroundColor = 'transparent';
    backgroundLayer.style.backgroundImage = 'none';
    document.body.dataset.hasBackground = 'false';
  }
}

function sendAction(action, messageId = null, payload = {}) {
  if (!state) return null;
  if ((action === 'loadMoreBefore' || action === 'loadMoreAfter') &&
      [...pendingActions.values()].includes(action)) return null;
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
  return requestId;
}

function requestMedia(handle) {
  if (!state || !isMediaHandle(handle) || pendingMedia.has(handle)) return;
  pendingMedia.add(handle);
  bridge.post({
    type: 'mediaRequest', handle,
    renderSessionId: state.renderSessionId,
    conversationId: state.conversationId,
    capabilityToken: state.capabilityToken,
  });
}

function actionLabel(action) {
  if (action === 'speak' && state?.display?.ttsActive === true) return t('stop');
  return t({
    copy: 'copy', edit: 'edit', resend: 'resend', regenerate: 'regenerate',
    quote: 'quote', translate: 'translate', speak: 'speak', share: 'share',
    fork: 'fork', select: 'select', delete: 'delete', multiAI: 'multiAI',
    more: 'more',
  }[action]);
}

const iconCodepoints = Object.freeze({
  copy: 57502,
  more: 57526,
  regenerate: 57669,
  speak: 57771,
  stop: 57475,
  translate: 57598,
  edit: 57849,
  resend: 57669,
  previous: 57454,
  next: 57455,
  bot: 57787,
  user: 57759,
  reasoning: 58310,
  tool: 57777,
  sparkle: 58386,
});

function iconNode(name, className = 'lucide-icon') {
  const node = document.createElement('span');
  node.className = className;
  node.setAttribute('aria-hidden', 'true');
  node.textContent = String.fromCodePoint(iconCodepoints[name] ?? iconCodepoints.sparkle);
  return node;
}

function iconButton(name, label, onClick, className = 'icon-action') {
  const node = button(label, onClick, className);
  node.title = label;
  node.replaceChildren(iconNode(name));
  return node;
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

function localExpansion(key, defaultValue) {
  if (!localExpansions.has(key)) {
    localExpansions.set(key, Boolean(defaultValue));
  }
  return localExpansions.get(key);
}

function updateDisclosure(root, header, body, expanded) {
  const previous = header.getAttribute('aria-expanded') === 'true';
  root.classList.toggle('is-expanded', expanded);
  header.setAttribute('aria-expanded', String(expanded));
  disclosureAnimations.get(body)?.cancel();
  if (!root.isConnected || previous === expanded) {
    body.hidden = !expanded;
    return;
  }
  body.hidden = false;
  if (typeof body.animate !== 'function' ||
      window.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches) {
    body.hidden = !expanded;
    return;
  }
  const animation = body.animate(
    expanded
      ? [{ opacity: 0, transform: 'translateY(-4px)' }, { opacity: 1, transform: 'translateY(0)' }]
      : [{ opacity: 1, transform: 'translateY(0)' }, { opacity: 0, transform: 'translateY(-4px)' }],
    { duration: 180, easing: 'ease-out' },
  );
  disclosureAnimations.set(body, animation);
  animation.finished.then(() => {
    if (disclosureAnimations.get(body) !== animation) return;
    disclosureAnimations.delete(body);
    body.hidden = header.getAttribute('aria-expanded') !== 'true';
  }).catch((error) => {
    if (error?.name !== 'AbortError') {
      bridge.post({ type: 'diagnostic', code: 'disclosure_animation_failed' });
    }
  });
}

function disclosure({
  key,
  label,
  body,
  expanded,
  className,
  icon = null,
  detailNode = null,
  onToggle,
}) {
  const root = document.createElement('section');
  root.className = `disclosure ${className}`;
  root.dataset.expansionKey = key;
  const header = button(label, () => {
    const previous = header.getAttribute('aria-expanded') === 'true';
    try {
      const requested = !previous;
      const resolved = onToggle?.(requested) ?? requested;
      updateDisclosure(root, header, body, Boolean(resolved));
    } catch (error) {
      updateDisclosure(root, header, body, previous);
      bridge.post({
        type: 'diagnostic',
        code: error?.message ?? 'disclosure_toggle_failed',
      });
    }
  }, 'disclosure-header');
  const title = document.createElement('span');
  title.className = 'disclosure-title';
  title.textContent = label;
  const leading = icon ? iconNode(icon, 'disclosure-icon') : null;
  const chevron = iconNode('next', 'disclosure-chevron');
  header.replaceChildren(...[leading, title, detailNode, chevron].filter(Boolean));
  root.append(header, body);
  updateDisclosure(root, header, body, Boolean(expanded));
  return root;
}

function stableTextKey(prefix, source) {
  let hash = 2166136261;
  for (let index = 0; index < source.length; index += 1) {
    hash ^= source.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return `${prefix}:${(hash >>> 0).toString(16)}`;
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

function normalizeCodeLanguage(language) {
  const normalized = language.trim().toLowerCase();
  return ({
    js: 'javascript',
    ts: 'typescript',
    sh: 'bash',
    zsh: 'bash',
    shell: 'bash',
    yml: 'yaml',
    py: 'python',
    rb: 'ruby',
    rs: 'rust',
    kt: 'kotlin',
    'c++': 'cpp',
    'c#': 'csharp',
    md: 'markdown',
    text: 'plaintext',
    txt: 'plaintext',
    plain: 'plaintext',
    plaintext: 'plaintext',
  }[normalized] ?? normalized) || 'plaintext';
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
    const highlightLanguage = normalizeCodeLanguage(language);
    const pre = code.parentElement;
    const source = code.textContent ?? '';
    if (highlightLanguage === 'mermaid' && !streaming) {
      renderMermaid(code.parentElement, code.textContent ?? '');
      continue;
    }
    if (highlightLanguage === 'html' && !streaming) addHtmlPreview(pre, code.textContent ?? '');
    const displaySource = source.replace(/(?:\r\n|\r|\n)+$/, '');
    code.classList.add('hljs');
    try {
      code.innerHTML = window.hljs.highlight(displaySource, {
        language: highlightLanguage,
        ignoreIllegals: true,
      }).value;
    } catch {
      code.textContent = displaySource;
      bridge.post({ type: 'diagnostic', code: 'highlight_block_failed' });
    }
    renderCodeBlock(pre, code, language, source);
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

function renderCodeBlock(pre, code, language, source) {
  const displaySource = code.textContent ?? '';
  const threshold = Number(state.display?.collapsedCodeLines ?? 0);
  const lineCount = (displaySource.match(/\n/g)?.length ?? 0) + 1;
  const collapsible = threshold > 0 && lineCount > threshold;
  const expansionKey = stableTextKey('code', source);
  const block = document.createElement('section');
  block.className = 'code-block';
  block.dataset.component = 'code-block';
  block.classList.toggle('is-wrapped', state.display?.wrapCode === true);
  if (collapsible) block.style.setProperty('--collapsed-lines', String(threshold));

  const header = document.createElement('div');
  header.className = 'code-block-header';
  const toggle = document.createElement('button');
  toggle.type = 'button';
  toggle.className = 'code-block-toggle';
  toggle.setAttribute('aria-label', collapsible ? t('expandCode') : t('code'));
  toggle.setAttribute('aria-expanded', String(!collapsible));
  const languageLabel = document.createElement('span');
  languageLabel.className = 'code-block-language';
  languageLabel.textContent = language.trim() || t('code');
  const chevron = iconNode('next', 'code-block-chevron');
  chevron.hidden = true;
  toggle.append(languageLabel, chevron);

  const copy = iconButton(
    'copy',
    t('copyCode'),
    () => sendAction('copyText', null, { text: source }),
    'code-block-action',
  );
  header.append(toggle, copy);

  const body = document.createElement('div');
  body.className = 'code-block-body';
  pre.className = 'code-block-pre';
  mountCodeBlock({ pre, block, header, body });

  const applyCodeExpansion = (expanded) => {
    block.classList.toggle('is-collapsed', !expanded);
    toggle.setAttribute('aria-expanded', String(expanded));
    toggle.setAttribute('aria-label', expanded ? t('collapseCode') : t('expandCode'));
    chevron.hidden = expanded;
  };
  if (collapsible) {
    toggle.addEventListener('click', () => {
      const expanded = !localExpansion(expansionKey, false);
      localExpansions.set(expansionKey, expanded);
      applyCodeExpansion(expanded);
    });
    applyCodeExpansion(localExpansion(expansionKey, false));
  }
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
  const frame = document.createElement('iframe');
  frame.setAttribute('sandbox', 'allow-scripts');
  frame.referrerPolicy = 'no-referrer';
  frame.srcdoc = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:">${source}`;
  const key = stableTextKey('html-preview', source);
  pre.after(disclosure({
    key,
    label: t('htmlPreview'),
    body: frame,
    expanded: localExpansion(key, false),
    className: 'html-preview',
    onToggle: (next) => {
      localExpansions.set(key, next);
      return next;
    },
  }));
}

function renderReasoning(message, parent) {
  const segments = message.reasoning ?? [];
  for (const [index, segment] of segments.entries()) renderReasoningSegment(message, segment, index, parent);
}

function createReasoningElapsedNode(segment) {
  if (segment.startAt == null) return null;
  const node = document.createElement('span');
  node.className = 'disclosure-detail reasoning-elapsed';
  node.dataset.reasoningElapsed = 'true';
  node.dataset.reasoningStartAt = String(segment.startAt);
  node.dataset.reasoningFinishedAt = String(segment.finishedAt ?? '');
  node.dataset.reasoningLoading = String(Boolean(segment.loading));
  node.textContent = formatReasoningElapsed(
    segment.startAt,
    segment.finishedAt,
    Boolean(segment.loading),
  );
  return node;
}

function refreshReasoningElapsed() {
  let hasLoading = false;
  for (const node of document.querySelectorAll('[data-reasoning-elapsed]')) {
    const loading = node.dataset.reasoningLoading === 'true';
    hasLoading ||= loading;
    node.textContent = formatReasoningElapsed(
      node.dataset.reasoningStartAt,
      node.dataset.reasoningFinishedAt,
      loading,
    );
  }
  if (!hasLoading && reasoningElapsedTimer != null) {
    clearInterval(reasoningElapsedTimer);
    reasoningElapsedTimer = null;
  }
}

function ensureReasoningElapsedTimer() {
  refreshReasoningElapsed();
  if (reasoningElapsedTimer == null &&
      document.querySelector('[data-reasoning-elapsed][data-reasoning-loading="true"]')) {
    reasoningElapsedTimer = setInterval(refreshReasoningElapsed, 100);
  }
}

function renderReasoningSegment(message, segment, index, parent) {
  const kind = segment.kind ?? 'legacy';
  const segmentIndex = Number.isInteger(segment.index) ? segment.index : index;
  const key = segment.key ?? `${message.id}:reasoning:${kind}:${segmentIndex}`;
  const authoritative = Boolean(segment.expanded);
  const expanded = kind === 'legacy'
    ? localExpansion(key, authoritative)
    : expansionCoordinator.value(key, authoritative);
  const body = document.createElement('div');
  body.className = 'thinking-body';
  body.append(markdownNode(segment.text ?? '', Boolean(segment.loading), 'reasoning'));
  const card = disclosure({
    key,
    label: segment.loading ? t('thinking') : t('reasoning'),
    body,
    expanded,
    className: 'thinking',
    icon: 'reasoning',
    detailNode: createReasoningElapsedNode(segment),
    onToggle: (next) => {
      if (kind === 'legacy') {
        localExpansions.set(key, next);
        return next;
      }
      return expansionCoordinator.toggle({
        key,
        authoritative,
        dispatch: (target) => sendAction('setReasoningExpanded', message.id, {
          kind,
          index: segmentIndex,
          expanded: target,
        }),
      });
    },
  });
  card.dataset.component = 'reasoning';
  card.classList.toggle('is-loading', Boolean(segment.loading));
  parent.append(card);
}

function appendConversationText(message, parent, content) {
  if (!content) return;
  const markdown = markdownNode(content, message.isStreaming, message.role);
  if (message.role === 'user') {
    parent.append(markdown);
    return;
  }
  const surface = document.createElement('div');
  surface.className = 'assistant-text-surface';
  surface.append(markdown);
  parent.append(surface);
}

function renderConversationBlocks(message, parent) {
  const reasoning = message.reasoning ?? [];
  const tools = message.tools ?? [];
  const splits = message.contentSplits ?? {};
  const offsets = splits.offsets ?? [];
  const reasoningCounts = splits.reasoningCounts ?? [];
  const toolCounts = splits.toolCounts ?? [];
  if (!offsets.length) {
    renderReasoning(message, parent);
    appendConversationText(message, parent, message.content);
    for (const tool of tools) renderTool(message, tool, parent);
    return;
  }
  let contentOffset = 0;
  let reasoningIndex = 0;
  let toolIndex = 0;
  for (let index = 0; index < offsets.length; index += 1) {
    const offset = Math.max(contentOffset, Math.min(message.content.length, offsets[index]));
    if (offset > contentOffset) {
      appendConversationText(
        message,
        parent,
        message.content.slice(contentOffset, offset),
      );
    }
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
  if (contentOffset < message.content.length) {
    appendConversationText(message, parent, message.content.slice(contentOffset));
  }
}

function groupChainCards(parent) {
  let chain = null;
  for (const child of [...parent.children]) {
    const isStep = child.dataset?.component === 'reasoning' ||
      child.dataset?.component === 'tool';
    if (!isStep) {
      chain = null;
      continue;
    }
    if (!chain) {
      chain = document.createElement('section');
      chain.className = 'chain-card';
      child.before(chain);
    }
    chain.append(child);
  }
}

function renderTool(message, tool, parent) {
  const key = `${message.id}:tool:${tool.id}`;
  const summary = state.display?.showToolResultSummary === true && tool.content != null
    ? String(tool.content).replace(/\s+/g, ' ').trim().slice(0, 72)
    : '';
  const label = `${tool.content == null ? t('toolCall') : t('toolResult')} ${tool.toolName}${summary ? ` · ${summary}` : ''}`.trim();
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
  const card = disclosure({
    key,
    label,
    body,
    expanded: localExpansion(key, false),
    className: 'tool',
    icon: 'tool',
    onToggle: (next) => {
      localExpansions.set(key, next);
      return next;
    },
  });
  card.dataset.component = 'tool';
  card.classList.toggle('is-loading', Boolean(tool.loading));
  parent.append(card);
}

function applyThinkingStepCollapse(message, parent) {
  if (state.display?.collapseThinkingSteps !== true) return;
  for (const [cardIndex, card] of [...parent.querySelectorAll(':scope > .chain-card')].entries()) {
    const steps = [...card.children].filter((node) =>
      node.dataset?.component === 'reasoning' || node.dataset?.component === 'tool');
    const hiddenCount = steps.length - 2;
    if (hiddenCount <= 0) continue;
    const key = `${message.id}:thinking-steps:${cardIndex}`;
    if (localExpansion(key, false)) continue;
    for (const step of steps.slice(0, hiddenCount)) step.hidden = true;
    const show = button(
      message.expandStepsLabel ?? String(hiddenCount),
      () => {
        localExpansions.set(key, true);
        for (const step of steps.slice(0, hiddenCount)) step.hidden = false;
        show.remove();
      },
      'show-thinking-steps',
    );
    steps[hiddenCount].before(show);
  }
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
    } else if (attachment.kind === 'image' && isMediaHandle(attachment.reference)) {
      requestMedia(attachment.reference);
    } else if (attachment.kind === 'file') {
      const file = document.createElement('div');
      file.className = 'attachment-file';
      file.dataset.component = 'attachment-file';
      file.textContent = attachment.name ?? attachment.mime ?? '';
      parent.append(file);
    }
  }
}

function mediaImage(reference, alt, monochrome = false) {
  const source = state.media?.[reference] ?? reference ?? '';
  if (!/^(data:|https?:)/.test(source)) {
    if (isMediaHandle(reference)) requestMedia(reference);
    return null;
  }
  const image = document.createElement('img');
  image.src = source;
  image.alt = alt ?? '';
  image.referrerPolicy = 'no-referrer';
  image.classList.toggle('is-monochrome', monochrome);
  return image;
}

function renderAvatar(message) {
  const isUser = message.role === 'user';
  const display = state.display ?? {};
  const assistant = state.assistant ?? {};
  const user = state.user ?? {};
  if (isUser && display.showUserAvatar === false) return null;
  if (!isUser && !assistant.useAvatar && display.showModelIcon === false) return null;

  const avatar = document.createElement('div');
  avatar.className = 'avatar';
  if (isUser) {
    const image = mediaImage(user.avatar, user.name, false);
    if (image) avatar.append(image);
    else if (user.avatarLabel) avatar.textContent = user.avatarLabel;
    else avatar.append(iconNode('user'));
    return avatar;
  }

  if (assistant.useAvatar) {
    const image = mediaImage(assistant.avatar, assistant.name, false);
    if (image) avatar.append(image);
    else if (assistant.avatarLabel) avatar.textContent = assistant.avatarLabel;
    else avatar.append(iconNode('bot'));
    return avatar;
  }
  avatar.classList.add('is-model-icon');
  const image = mediaImage(
    message.modelIcon,
    message.modelId,
    Boolean(message.modelIconMonochrome),
  );
  if (image) avatar.append(image);
  else if (message.modelId?.trim()) {
    avatar.textContent = [...message.modelId.trim()][0].toUpperCase();
  } else {
    avatar.append(iconNode('bot'));
  }
  return avatar;
}

function renderMessageHeader(message) {
  const isUser = message.role === 'user';
  const display = state.display ?? {};
  const assistant = state.assistant ?? {};
  const header = document.createElement('div');
  header.className = 'message-header';
  const meta = document.createElement('div');
  meta.className = 'meta';
  if ((isUser && display.showUserName !== false) || (!isUser && display.showModelName !== false)) {
    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = isUser
      ? (state.user?.name ?? t('user'))
      : (assistant.useName ? (assistant.name || t('assistant')) : (message.modelId || t('assistant')));
    meta.append(name);
  }
  if ((isUser && display.showUserTimestamp !== false) || (!isUser && display.showModelTimestamp !== false)) {
    const time = document.createElement('time');
    time.dateTime = message.timestamp;
    time.textContent = new Intl.DateTimeFormat(undefined, {
      month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
    }).format(new Date(message.timestamp));
    meta.append(time);
  }
  const avatar = renderAvatar(message);
  if (isUser) header.append(meta, ...[avatar].filter(Boolean));
  else header.append(...[avatar].filter(Boolean), meta);
  return header.childElementCount ? header : null;
}

function renderMessageActions(message) {
  const actions = document.createElement('div');
  actions.className = 'actions';
  actions.dataset.component = 'message-actions';
  for (const action of message.actions ?? []) {
    const icon = action === 'speak' && state.display?.ttsActive === true
      ? 'stop'
      : ({ copy: 'copy', edit: 'edit', resend: 'resend', regenerate: 'regenerate',
        speak: 'speak', translate: 'translate', more: 'more' }[action] ?? 'sparkle');
    actions.append(iconButton(icon, actionLabel(action), () => sendAction(action, message.id)));
  }
  if ((message.versionCount ?? 1) > 1) {
    const previous = iconButton('previous', t('previousVersion'),
      () => sendAction('version', message.id, { delta: -1 }), 'version-action');
    previous.disabled = (message.versionIndex ?? 0) <= 0;
    const version = document.createElement('span');
    version.className = 'version-label';
    version.textContent = `${(message.versionIndex ?? 0) + 1}/${message.versionCount}`;
    const next = iconButton('next', t('nextVersion'),
      () => sendAction('version', message.id, { delta: 1 }), 'version-action');
    next.disabled = (message.versionIndex ?? 0) >= message.versionCount - 1;
    actions.append(previous, version, next);
  }
  if (message.role !== 'user' && state.display?.showTokenStats !== false && message.tokens != null) {
    const tokens = document.createElement('span');
    tokens.className = 'token-stats';
    tokens.textContent = `${message.tokens} ${t('tokens')}`;
    tokens.title = [
      message.promptTokens == null ? null : `${message.promptTokens}`,
      message.completionTokens == null ? null : `${message.completionTokens}`,
      message.cachedTokens == null ? null : `${message.cachedTokens}`,
    ].filter(Boolean).join(' / ');
    actions.append(tokens);
  }
  return actions.childElementCount ? actions : null;
}

function renderSuggestions() {
  if (!state.suggestions?.length) return null;
  const suggestions = document.createElement('div');
  suggestions.className = 'suggestions';
  for (const suggestion of state.suggestions.slice(0, 3)) {
    suggestions.append(button(
      suggestion,
      () => sendAction('suggestion', null, { text: suggestion }),
      'suggestion',
    ));
  }
  return suggestions;
}

function renderMessage(message, isLast = false) {
  const article = document.createElement('article');
  article.className = `message ${message.role === 'user' ? 'is-user' : 'is-assistant'}`;
  article.dataset.component = 'message';
  article.dataset.role = message.role;
  article.dataset.selected = String(Boolean(message.selected));
  article.tabIndex = -1;

  const main = document.createElement('div');
  main.className = 'message-main';
  const header = renderMessageHeader(message);

  const attachments = document.createElement('div');
  attachments.className = 'attachments';
  renderAttachments(message, attachments);

  const bubble = document.createElement('div');
  bubble.className = 'bubble';
  bubble.dataset.component = 'message-bubble';
  renderConversationBlocks(message, bubble);
  groupChainCards(bubble);
  applyThinkingStepCollapse(message, bubble);
  if (message.translation) {
    const key = `${message.id}:translation`;
    bubble.append(disclosure({
      key,
      label: t('translation'),
      body: markdownNode(message.translation, message.isStreaming),
      expanded: localExpansion(key, true),
      className: 'translation',
      icon: 'translate',
      onToggle: (next) => {
        localExpansions.set(key, next);
        return next;
      },
    }));
  }
  if (message.role !== 'user' && message.isStreaming && !bubble.childElementCount) {
    const streaming = document.createElement('div');
    streaming.className = 'streaming-indicator';
    streaming.setAttribute('aria-label', t('assistant'));
    streaming.append(document.createElement('i'), document.createElement('i'), document.createElement('i'));
    bubble.append(streaming);
  }
  const actions = message.selecting || (message.role !== 'user' && message.isStreaming)
    ? null
    : renderMessageActions(message);
  const suggestions = message.role !== 'user' && isLast && !message.isStreaming
    ? renderSuggestions()
    : null;
  main.append(
    ...[
      header,
      attachments.childElementCount ? attachments : null,
      bubble.childElementCount ? bubble : null,
      actions,
      suggestions,
    ].filter(Boolean),
  );
  article.append(main);
  article.addEventListener('contextmenu', (event) => {
    event.preventDefault();
    if (!message.selecting) sendAction('more', message.id);
  });
  if (message.selecting) {
    article.addEventListener('click', (event) => {
      if (!event.target.closest('button, a, input, textarea')) sendAction('select', message.id);
    });
  }
  return article;
}

function render() {
  if (!state) return;
  const sameSession = renderedSessionId === state.renderSessionId;
  const savedViewport = sameSession
    ? null
    : viewportForSavedAnchor({
      messageIds: (state.messages ?? []).map((message) => message.id),
      heights: (state.messages ?? []).map(messageHeight),
      anchor: state.initialViewportAnchor,
      viewportHeight: timeline.clientHeight,
    });
  const messages = state.messages ?? [];
  const missingSavedAnchor = !sameSession &&
    state.initialViewportAnchor != null && savedViewport == null;
  const viewport = savedViewport ?? (missingSavedAnchor
    ? {
      scrollTop: messages.reduce((sum, message) => sum + messageHeight(message), 0),
      viewportHeight: timeline.clientHeight,
      anchor: null,
    }
    : captureViewport(timeline, { preserve: sameSession }));
  applyTheme();
  resizeObserver?.disconnect();
  resizeObserver ??= new ResizeObserver(handleMeasuredHeights);
  const fragment = document.createDocumentFragment();
  const observedSlots = [];
  if (messages.length === 0) {
    renderedRange = { start: 0, end: 0 };
    topSpacer = null;
    bottomSpacer = null;
    const empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = t('empty');
    fragment.append(empty);
    timeline.replaceChildren(fragment);
    renderedSessionId = state.renderSessionId;
    renderedConversationId = state.conversationId;
    ensureReasoningElapsedTimer();
    restoreViewport(timeline, viewport);
    sendViewportMetrics();
    return;
  }
  const range = visibleRange({
    heights: messages.map(messageHeight),
    scrollTop: viewport.scrollTop,
    viewportHeight: viewport.viewportHeight,
    overscan: virtualOverscan(viewport.viewportHeight),
  });
  renderedRange = { start: range.start, end: range.end };
  topSpacer = document.createElement('div');
  topSpacer.className = 'spacer';
  topSpacer.style.height = `${range.top}px`;
  bottomSpacer = document.createElement('div');
  bottomSpacer.className = 'spacer';
  bottomSpacer.style.height = `${range.bottom}px`;
  fragment.append(topSpacer);
  if (state.preset && range.start === 0) {
    const preset = document.createElement('div');
    preset.className = 'suggestions';
    preset.append(button(state.preset.label, () => sendAction('togglePresets'), 'suggestion'));
    fragment.append(preset);
  }
  for (const [visibleIndex, message] of messages.slice(range.start, range.end).entries()) {
    const slot = document.createElement('div');
    slot.className = 'message-slot';
    slot.dataset.messageId = message.id;
    const node = renderMessage(message, range.start + visibleIndex === messages.length - 1);
    slot.append(node);
    if (message.showContextDivider) {
      const divider = document.createElement('div');
      divider.className = 'context-divider';
      divider.textContent = t('contextDivider');
      slot.append(divider);
    }
    fragment.append(slot);
    observedSlots.push(slot);
  }
  fragment.append(bottomSpacer);
  timeline.replaceChildren(fragment);
  for (const slot of observedSlots) resizeObserver.observe(slot);
  renderedSessionId = state.renderSessionId;
  renderedConversationId = state.conversationId;
  ensureReasoningElapsedTimer();
  restoreViewport(timeline, viewport);
  sendViewportMetrics();
}

function handleMeasuredHeights(entries) {
  if (!state?.messages?.length) return;
  const viewport = captureViewport(timeline);
  let changed = false;
  for (const entry of entries) {
    const id = entry.target.dataset.messageId;
    const height = normalizeMeasuredHeight(
      entry.borderBoxSize?.[0]?.blockSize ?? entry.contentRect.height,
    );
    if (id && height != null && Math.abs((heights.get(id) ?? 0) - height) > 1) {
      heights.set(id, height);
      changed = true;
    }
  }
  if (!changed) return;
  if (touchActive || userScrolling) {
    requestRender();
    return;
  }
  const range = visibleRange({
    heights: state.messages.map(messageHeight),
    scrollTop: viewport.scrollTop,
    viewportHeight: viewport.viewportHeight,
    overscan: virtualOverscan(viewport.viewportHeight),
  });
  if (rangeChanged(renderedRange, range)) {
    requestRender();
    return;
  }
  if (topSpacer) topSpacer.style.height = `${range.top}px`;
  if (bottomSpacer) bottomSpacer.style.height = `${range.bottom}px`;
  restoreViewport(timeline, viewport);
  sendViewportMetrics();
}

const scheduleRender = createFrameCoalescer(render);
const renderGate = createRenderGate(scheduleRender);
function requestRender() { renderGate.request(); }
function setRenderBlocked(value) { renderGate.setBlocked(value); }
const sendViewportMetrics = createFrameCoalescer(() => {
  const anchor = captureAnchor(timeline);
  bridge.post({
    type: 'viewportMetrics',
    pixels: timeline.scrollTop,
    maxExtent: Math.max(0, timeline.scrollHeight - timeline.clientHeight),
    isUserScrolling: userScrolling,
    renderSessionId: renderedSessionId,
    conversationId: renderedConversationId,
    anchorMessageId: anchor?.id ?? null,
    anchorOffset: anchor?.offset ?? 0,
  });
});
function releaseScrollStopLock() {
  scrollStopLock = false;
  if (scrollStopFrame) {
    cancelAnimationFrame(scrollStopFrame);
    scrollStopFrame = 0;
  }
}
function restoreScrollStopPosition() {
  if (!scrollStopLock) return;
  if (timeline.scrollTop !== scrollStopTop || timeline.scrollLeft !== scrollStopLeft) {
    timeline.scrollTo({ left: scrollStopLeft, top: scrollStopTop, behavior: 'auto' });
  }
}
function enforceScrollStop() {
  if (!scrollStopLock) {
    scrollStopFrame = 0;
    return;
  }
  restoreScrollStopPosition();
  scrollStopFrame = requestAnimationFrame(enforceScrollStop);
}
function stopScrolling() {
  // The Flutter/Android bridge may deliver this call slightly after the DOM
  // pointer event. Never restart the lock after this gesture already became a
  // real drag.
  if (gestureActive && gestureIntent !== 'hold') return;
  if (!scrollStopLock) {
    scrollStopLock = true;
    scrollStopTop = timeline.scrollTop;
    scrollStopLeft = timeline.scrollLeft;
  }
  timeline.style.scrollBehavior = 'auto';
  restoreScrollStopPosition();
  if (!scrollStopFrame) scrollStopFrame = requestAnimationFrame(enforceScrollStop);
}
function markUserScroll() {
  const firstIntent = !userScrolling;
  userScrolling = true;
  setRenderBlocked(true);
  if (firstIntent) sendViewportMetrics();
  clearTimeout(userScrollTimer);
  userScrollTimer = setTimeout(() => {
    userScrolling = false;
    sendViewportMetrics();
    if (!touchActive) setRenderBlocked(false);
  }, 800);
}
timeline.addEventListener('wheel', markUserScroll, { passive: true });
timeline.addEventListener('pointerdown', (event) => {
  gestureActive = true;
  gestureIntent = 'hold';
  pointerStartX = event.clientX;
  pointerStartY = event.clientY;
  stopScrolling();
}, { passive: true });
timeline.addEventListener('pointermove', (event) => {
  if (pointerStartX == null || pointerStartY == null) return;
  const intent = verticalGestureIntent({
    startX: pointerStartX,
    startY: pointerStartY,
    currentX: event.clientX,
    currentY: event.clientY,
  });
  if (intent === 'hold') return;
  gestureIntent = intent;
  releaseScrollStopLock();
  pointerStartX = null;
  pointerStartY = null;
  if (intent === 'vertical') markUserScroll();
}, { passive: true });
timeline.addEventListener('pointerup', () => {
  gestureActive = false;
  gestureIntent = 'idle';
  pointerStartX = null;
  pointerStartY = null;
  releaseScrollStopLock();
}, { passive: true });
timeline.addEventListener('pointercancel', () => {
  if (touchActive && gestureIntent === 'hold') return;
  gestureActive = false;
  gestureIntent = 'idle';
  pointerStartX = null;
  pointerStartY = null;
  releaseScrollStopLock();
}, { passive: true });
timeline.addEventListener('touchstart', (event) => {
  gestureActive = true;
  gestureIntent = 'hold';
  touchActive = true;
  stopScrolling();
  setRenderBlocked(true);
  touchStartX = event.touches[0]?.clientX ?? null;
  touchStartY = event.touches[0]?.clientY ?? null;
}, { passive: true });
timeline.addEventListener('touchmove', (event) => {
  const currentX = event.touches[0]?.clientX;
  const current = event.touches[0]?.clientY;
  if (touchStartX == null || touchStartY == null ||
      currentX == null || current == null) return;
  const intent = verticalGestureIntent({
    startX: touchStartX,
    startY: touchStartY,
    currentX,
    currentY: current,
  });
  if (intent === 'hold') {
    restoreScrollStopPosition();
    if (scrollStopLock && event.cancelable) {
      event.preventDefault();
    }
    return;
  }
  gestureIntent = intent;
  releaseScrollStopLock();
  touchStartX = null;
  touchStartY = null;
  if (intent === 'vertical') markUserScroll();
}, { passive: false });
timeline.addEventListener('touchend', () => {
  gestureActive = false;
  gestureIntent = 'idle';
  releaseScrollStopLock();
  touchActive = false;
  touchStartX = null;
  touchStartY = null;
  if (!userScrolling) setRenderBlocked(false);
}, { passive: true });
timeline.addEventListener('touchcancel', () => {
  gestureActive = false;
  gestureIntent = 'idle';
  releaseScrollStopLock();
  touchActive = false;
  touchStartX = null;
  touchStartY = null;
  if (!userScrolling) setRenderBlocked(false);
}, { passive: true });
timeline.addEventListener('scroll', () => {
  if (scrollStopLock) {
    restoreScrollStopPosition();
    return;
  }
  if (userScrolling) markUserScroll();
  if (state?.messages?.length) {
    const range = visibleRange({
      heights: state.messages.map(messageHeight),
      scrollTop: timeline.scrollTop,
      viewportHeight: timeline.clientHeight,
      overscan: virtualOverscan(timeline.clientHeight),
    });
    if (rangeChanged(renderedRange, range)) requestRender();
  }
  sendViewportMetrics();
  if (timeline.scrollTop < 180 && state?.hasMoreBefore) sendAction('loadMoreBefore');
  if (timeline.scrollHeight - timeline.scrollTop - timeline.clientHeight < 180 && state?.hasMoreAfter) sendAction('loadMoreAfter');
}, { passive: true });
timeline.addEventListener('keydown', (event) => {
  if (event.key === 'Home') {
    markUserScroll();
    timeline.scrollTo({ top: 0, behavior: 'smooth' });
  } else if (event.key === 'End') {
    markUserScroll();
    timeline.scrollTo({ top: timeline.scrollHeight, behavior: 'smooth' });
  } else if (event.key === 'PageUp') {
    markUserScroll();
    timeline.scrollBy({ top: -timeline.clientHeight * .85, behavior: 'smooth' });
  } else if (event.key === 'PageDown') {
    markUserScroll();
    timeline.scrollBy({ top: timeline.clientHeight * .85, behavior: 'smooth' });
  } else if (event.key === 'ArrowUp' || event.key === 'ArrowDown' ||
      event.key === ' ' || event.key === 'Spacebar') {
    markUserScroll();
  }
});
window.addEventListener('resize', requestRender);

function prepareProgrammaticNavigation() {
  releaseScrollStopLock();
  clearTimeout(userScrollTimer);
  userScrollTimer = null;
  userScrolling = false;
  setRenderBlocked(false);
}

function handleViewportCommand(envelope) {
  const command = envelope.command;
  const payload = envelope.payload ?? {};
  const behavior = payload.animate === false ? 'auto' : 'smooth';
  prepareProgrammaticNavigation();
  if (command === 'top') timeline.scrollTo({ top: 0, behavior });
  else if (command === 'bottom') timeline.scrollTo({ top: timeline.scrollHeight, behavior });
  else if (command === 'message') scrollToMessage(payload.messageId, behavior);
  else if (command === 'previousQuestion') jumpQuestion(-1);
  else if (command === 'nextQuestion') jumpQuestion(1);
  else if (command === 'restoreAnchor') restoreMessageAnchor(payload);
  sendViewportMetrics();
}

function restoreMessageAnchor(anchor) {
  const viewport = viewportForSavedAnchor({
    messageIds: (state?.messages ?? []).map((message) => message.id),
    heights: (state?.messages ?? []).map(messageHeight),
    anchor,
    viewportHeight: timeline.clientHeight,
  });
  if (!viewport) return false;
  timeline.scrollTo({ top: viewport.scrollTop, behavior: 'auto' });
  requestRender();
  requestAnimationFrame(() => {
    restoreAnchor(timeline, viewport.anchor);
    sendViewportMetrics();
  });
  return true;
}

function scrollToMessage(messageId, behavior = 'smooth') {
  const index = state?.messages?.findIndex((message) => message.id === messageId) ?? -1;
  if (index < 0) return;
  const top = state.messages.slice(0, index).reduce((sum, message) => sum + messageHeight(message), 0);
  timeline.scrollTo({ top, behavior });
  requestRender();
  requestAnimationFrame(() => timeline.querySelector(`[data-message-id="${CSS.escape(messageId)}"]`)?.focus({ preventScroll: true }));
}

function jumpQuestion(delta) {
  const messages = state?.messages ?? [];
  if (!messages.length) return;
  const anchor = captureAnchor(timeline);
  let index = messages.findIndex((message) => message.id === anchor?.id);
  if (index < 0) index = delta > 0 ? 0 : messages.length - 1;
  const next = index + delta;
  if (next < 0 || next >= messages.length) return;
  scrollToMessage(messages[next].id);
}

window.CuplivoWeb = {
  stopScrolling,
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
            requestRender();
          }
        } else {
          const previousSessionId = state?.renderSessionId;
          state = reduceEnvelope(state, payload);
          if (previousSessionId && previousSessionId !== state?.renderSessionId) {
            expansionCoordinator.clear();
            localExpansions.clear();
            pendingActions.clear();
            pendingMedia.clear();
            heights.clear();
          }
          requestRender();
        }
      } else if (envelope.type === 'messagePatches') {
        state = reduceEnvelope(state, envelope); requestRender();
      } else if (envelope.type === 'actionResult') {
        pendingActions.delete(envelope.requestId);
        if (expansionCoordinator.resolve(envelope.requestId, envelope.ok === true)) {
          requestRender();
        }
      }
      else if (envelope.type === 'mediaError') pendingMedia.delete(envelope.handle);
      else if (envelope.type === 'viewportCommand') handleViewportCommand(envelope);
    } catch (error) {
      bridge.post({ type: 'diagnostic', code: error?.message ?? 'receive_failed' });
    }
  },
};
window.chrome?.webview?.addEventListener('message', (event) => window.CuplivoWeb.receive(event.data));
bridge.post({ type: 'ready', protocolVersion: PROTOCOL_VERSION, assetVersion: ASSET_VERSION });
