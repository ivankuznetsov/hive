// Progressive enhancement: raw patches remain readable if loading/rendering fails.
let renderer;
async function enhance(host) {
  if (host.dataset.diffReady) return;
  const raw = host.querySelector('[data-diff-raw]');
  if (!raw || !raw.textContent.includes('diff --git ')) return;
  host.dataset.diffReady = 'loading';
  try {
    renderer ||= import('lib/diff_renderer');
    const { Diff2HtmlUI } = await renderer;
    if (!host.isConnected) return;
    const output = document.createElement('div');
    output.className = 'diff-rendered';
    const toolbar = document.createElement('div');
    toolbar.className = 'diff-toolbar';
    const modes = [['line-by-line', 'Unified'], ['side-by-side', 'Split'], ['raw', 'Raw']];
    const buttons = [];
    function draw(mode) {
      if (mode !== 'raw') {
        const view = new Diff2HtmlUI(output, raw.textContent, {
          outputFormat: mode, drawFileList: true, fileListStartVisible: true,
          fileContentToggle: true, matching: 'lines', matchWordsThreshold: 0.25,
          maxLineLengthHighlight: 1000, diffMaxLineLength: 10000,
          colorScheme: 'auto', synchronisedScroll: true, stickyFileHeaders: false
        });
        view.draw();
        // Anchors must stay within the current embedded workspace, not navigate
        // its host page. Give every viewer's file targets distinct IDs.
        const prefix = host.id || (host.id = `diff-viewer-${++initDiffViewers.serial}`);
        for (const el of output.querySelectorAll('[id]')) el.id = `${prefix}-${el.id}`;
        for (const link of output.querySelectorAll('a[href^="#"]')) {
          link.setAttribute('href', `#${prefix}-${link.getAttribute('href').slice(1)}`);
        }
        for (const table of output.querySelectorAll('.d2h-file-diff, .d2h-files-diff')) {
          table.tabIndex = 0;
          table.setAttribute('role', 'region');
          table.setAttribute('aria-label', 'File diff');
        }
      }
      output.hidden = mode === 'raw';
      raw.hidden = mode !== 'raw';
      for (const [button, value] of buttons) button.setAttribute('aria-pressed', String(value === mode));
    }
    for (const [mode, label] of modes) {
      const button = document.createElement('button');
      button.type = 'button'; button.textContent = label;
      button.addEventListener('click', () => draw(mode));
      buttons.push([button, mode]); toolbar.append(button);
    }
    toolbar.setAttribute('role', 'group'); toolbar.setAttribute('aria-label', 'Diff view');
    host.insertBefore(toolbar, raw); host.append(output);
    output.addEventListener('click', event => {
      const link = event.target.closest('a[href^="#"]');
      if (!link) return;
      const target = document.getElementById(link.getAttribute('href').slice(1));
      if (target && host.contains(target)) { event.preventDefault(); event.stopPropagation(); target.scrollIntoView({block:'start'}); }
    });
    draw('line-by-line');
    host.dataset.diffReady = 'ready';
  } catch {
    host.querySelector('.diff-rendered')?.remove();
    host.querySelector('.diff-toolbar')?.remove();
    raw.hidden = false;
    host.dataset.diffReady = 'fallback';
  }
}
export function initDiffViewers(root = document) {
  for (const host of root.querySelectorAll('[data-diff-viewer]')) enhance(host);
}
initDiffViewers.serial = 0;
if (typeof document !== 'undefined') {
  let queued = false;
  const scan = () => {
    if (queued) return;
    queued = true;
    queueMicrotask(() => { queued = false; initDiffViewers(); });
  };
  new MutationObserver(scan).observe(document.documentElement, {childList: true, subtree: true});
  document.addEventListener('turbo:load', scan);
  document.addEventListener('turbo:frame-load', scan);
  scan();
}
