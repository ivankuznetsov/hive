import { initWaitlist } from './waitlist.mjs';

export const SNAPSHOT_ACTIONS = {
  answer: 'Answering a question',
  'install-workflow': 'Installing a workflow',
  'update-module': 'Updating a module',
  'uninstall-module': 'Uninstalling a module',
  'install-module': 'Installing a module'
};

export function snapshotActionMessage(action) {
  const label = SNAPSHOT_ACTIONS[action] || 'This action';
  return `${label} requires a running Hive installation. This saved snapshot is read-only.`;
}

function showActionNote(action) {
  const note = document.getElementById('snapshot-action-note');
  if (!note) return;
  const template = document.getElementById('snapshot-action-template');
  note.replaceChildren();
  note.append(`${snapshotActionMessage(action)} `);
  if (template) note.append(template.content.cloneNode(true));
  note.hidden = false;
  note.tabIndex = -1;
  note.focus({ preventScroll: true });
}

export function start() {
  let config = {};
  try {
    config = JSON.parse(document.getElementById('demo-config').textContent);
  } catch {
    config = {};
  }
  initWaitlist(config);
  document.addEventListener('click', event => {
    const control = event.target.closest('[data-snapshot-action]');
    if (!control) return;
    event.preventDefault();
    showActionNote(control.dataset.snapshotAction);
  });
}

if (typeof document !== 'undefined') start();
