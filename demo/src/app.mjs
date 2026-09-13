import { initWaitlist } from './waitlist.mjs';

export const STORAGE_KEY = 'hive-demo-v1';
export function validState(manifest, candidate) {
  return Object.hasOwn(manifest.states, candidate) ? candidate : manifest.initial;
}
export function parseRoute(hash, manifest, stateId) {
  const parts = hash.replace(/^#\/?/, '').split('/');
  const state = manifest.states[stateId];
  if (parts[0] !== 'task' || !Object.hasOwn(state.tasks, parts[1])) return { task: null, panel: null, hash: '#/' };
  const task = parts[1];
  const panel = ['overview', 'plan', 'diff', 'evidence'].includes(parts[2]) && state.tasks[task][parts[2]] ? parts[2] : 'overview';
  return { task, panel, hash: `#/task/${task}/${panel}` };
}
export function nextState(manifest, stateId, answer) {
  const state = manifest.states[stateId];
  if (state.phase === 'question') {
    return ['system', 'manual'].includes(answer) ? validState(manifest, `${answer}-plan`) : stateId;
  }
  return state.next ? validState(manifest, state.next) : stateId;
}

async function start() {
  initWaitlist(JSON.parse(document.getElementById('demo-config').textContent));
  const status = document.getElementById('demo-status');
  const content = document.getElementById('demo-content');
  const story = document.getElementById('demo-story');
  const reset = document.getElementById('demo-reset');
  let manifest;
  try {
    const response = await fetch('manifest.json');
    if (!response.ok) throw new Error('manifest');
    manifest = await response.json();
  } catch {
    status.textContent = 'The interactive demo could not load. Refresh to try again; the example board is still available below.';
    return;
  }
  let stateId = manifest.initial;
  try { stateId = validState(manifest, sessionStorage.getItem(STORAGE_KEY)); } catch { /* Tab memory remains usable when storage is blocked. */ }
  let navigationHash = location.hash.startsWith('#/') ? location.hash : '#/';
  let renderId = 0;
  let request;
  const save = () => { try { sessionStorage.setItem(STORAGE_KEY, stateId); } catch { /* Keep progress in this tab's memory. */ } };
  const button = (label, action, primary = false) => {
    const element = document.createElement('button');
    element.type = 'button'; element.textContent = label;
    element.className = `demo-button${primary ? ' demo-primary' : ''}`;
    element.addEventListener('click', action);
    return element;
  };
  function drawStory(route) {
    story.replaceChildren();
    story.hidden = route.task !== manifest.featured;
    if (story.hidden) return;
    const state = manifest.states[stateId];
    const heading = document.createElement('h2');
    const descriptions = {
      question: ['Start with a decision', 'Should dark mode follow the system setting, or use a manual switch? Choose an answer to see its prepared plan.'],
      plan: ['Your answer becomes a plan', 'Read the prepared plan below, then see implementation begin.'],
      implementing: ['Work is underway', 'Explore the example changes and evidence, then see the review stage.'],
      review: ['A result you can inspect', 'Read the prepared diff and test evidence, then view the completed outcome.'],
      completed: ['Ready to give Hive your own tasks?', 'Run Hive on your machine today, or join the waitlist for Hive Cloud.']
    };
    const [title, description] = descriptions[state.phase] || descriptions.question;
    heading.textContent = title;
    const paragraph = document.createElement('p'); paragraph.textContent = description;
    const actions = document.createElement('div'); actions.className = 'demo-actions';
    story.append(heading, paragraph, actions);
    if (state.phase === 'question') {
      for (const [answer, label] of [['system', 'Follow system setting'], ['manual', 'Use a manual switch']]) {
        actions.append(button(label, () => advance(answer), answer === 'system'));
      }
    } else if (state.phase === 'completed') {
      const join = button('Join Hive Cloud waitlist', () => {}, true); join.dataset.waitlistOpen = '';
      const local = document.createElement('a'); local.className = 'demo-button'; local.href = 'https://hivecli.sh'; local.textContent = 'Run locally ↗';
      actions.append(join, local);
    } else {
      actions.append(button('Next demo step', () => advance(), true));
    }
    if (state.phase !== 'completed') {
      const note = document.createElement('small'); note.textContent = 'These controls advance prepared examples. Hive runs its automatic steps without these demo clicks.'; story.append(note);
    }
  }
  async function render(focus = false) {
    const id = ++renderId;
    request?.abort(); request = new AbortController();
    const route = parseRoute(navigationHash, manifest, stateId);
    navigationHash = route.hash;
    if ((!location.hash || location.hash.startsWith('#/')) && location.hash !== route.hash) history.replaceState(null, '', route.hash);
    drawStory(route);
    const state = manifest.states[stateId];
    const path = route.task ? state.tasks[route.task][route.panel] : state.board;
    content.setAttribute('aria-busy', 'true');
    try {
      const response = await fetch(path, { signal: request.signal });
      if (!response.ok) throw new Error('fragment');
      const html = await response.text();
      if (id !== renderId) return;
      content.innerHTML = html;
      if (route.task) {
        const header = document.createElement('header'); header.className = 'demo-task-header';
        const back = document.createElement('a'); back.href = '#/'; back.textContent = '← Example project board';
        const title = document.createElement('h2'); title.textContent = manifest.tasks.find(task => task.slug === route.task)?.title || route.task;
        const tabs = document.createElement('nav'); tabs.className = 'demo-task-tabs'; tabs.setAttribute('aria-label', 'Task panels');
        for (const [panel, label] of [['overview', 'Overview'], ['plan', 'Plan'], ['diff', 'Changes'], ['evidence', 'Test evidence']]) {
          if (!state.tasks[route.task][panel]) continue;
          const link = document.createElement('a'); link.href = `#/task/${route.task}/${panel}`; link.textContent = label;
          if (route.panel === panel) link.setAttribute('aria-current', 'page');
          tabs.append(link);
        }
        header.append(back, title, tabs); content.prepend(header);
      }
      status.textContent = route.task ? `${manifest.tasks.find(task => task.slug === route.task)?.title || route.task} · ${route.panel}` : 'Example project board';
      if (focus) content.focus({ preventScroll: true });
    } catch (error) {
      if (id !== renderId || error.name === 'AbortError') return;
      content.replaceChildren();
      const notice = document.createElement('p'); notice.className = 'demo-notice'; notice.textContent = 'This example could not load.';
      content.append(notice, button('Try again', () => render()));
      status.textContent = 'Unable to load this example. Try again.';
    } finally { if (id === renderId) content.removeAttribute('aria-busy'); }
  }
  function advance(answer) { stateId = nextState(manifest, stateId, answer); save(); render(true); }
  reset.hidden = false;
  reset.addEventListener('click', () => {
    stateId = manifest.initial; save();
    navigationHash = '#/';
    history.replaceState(null, '', '#/');
    render(true);
  });
  document.addEventListener('click', event => {
    const anchor = event.target.closest('a[href^="#"]');
    if (!anchor || event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const href = anchor.getAttribute('href');
    if (href.startsWith('#/')) return;
    let target;
    try { target = document.getElementById(decodeURIComponent(href.slice(1))); } catch { return; }
    if (!target) return;
    event.preventDefault();
    target.scrollIntoView({ block: 'start' });
    if (!target.hasAttribute('tabindex')) target.setAttribute('tabindex', '-1');
    target.focus({ preventScroll: true });
  });
  window.addEventListener('hashchange', () => {
    // Artifact outlines and the skip link remain ordinary in-page anchors.
    if (!location.hash || location.hash.startsWith('#/')) {
      navigationHash = location.hash;
      render(true);
    }
  });
  await render();
}

if (typeof document !== 'undefined') start();
