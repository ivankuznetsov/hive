let challengeScript;
function loadTurnstile() {
  if (window.turnstile) return Promise.resolve(window.turnstile);
  if (challengeScript) return challengeScript;
  challengeScript = new Promise((resolve, reject) => {
    const script = document.createElement('script');
    const timeout = setTimeout(() => { script.remove(); reject(new Error('challenge timeout')); }, 12000);
    script.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';
    script.async = true;
    script.onload = () => { clearTimeout(timeout); window.turnstile ? resolve(window.turnstile) : reject(new Error('challenge unavailable')); };
    script.onerror = () => { clearTimeout(timeout); script.remove(); reject(new Error('challenge unavailable')); };
    document.head.append(script);
  }).catch(error => { challengeScript = null; throw error; });
  return challengeScript;
}

export function initWaitlist(config) {
  const dialog = document.getElementById('waitlist-dialog');
  const form = document.getElementById('waitlist-form');
  const email = document.getElementById('waitlist-email');
  const status = document.getElementById('waitlist-status');
  const submit = document.getElementById('waitlist-submit');
  const challenge = document.getElementById('waitlist-challenge');
  const enabled = config.waitlistEnabled === true && typeof config.turnstileSiteKey === 'string' && config.turnstileSiteKey.length > 0;
  let trigger, token = '', widget, busy = false, generation = 0, request, successful = false;
  function removeChallenge() {
    token = ''; submit.disabled = true;
    if (widget !== undefined && window.turnstile) window.turnstile.remove(widget);
    widget = undefined; challenge.replaceChildren();
  }
  async function freshChallenge() {
    removeChallenge();
    const current = ++generation;
    if (!enabled || !dialog.open || successful) return;
    try {
      const api = await loadTurnstile();
      if (current !== generation || !dialog.open) return;
      widget = api.render(challenge, {
        sitekey: config.turnstileSiteKey,
        action: 'waitlist',
        callback: value => {
          if (current !== generation || !dialog.open) return;
          token = value; submit.disabled = busy;
        },
        'expired-callback': () => {
          if (current !== generation) return;
          token = ''; submit.disabled = true;
          // The pending response owns completion; renewing now would invalidate it.
          if (busy) return;
          status.textContent = 'Verification expired. Complete the new verification to continue.';
          freshChallenge();
        },
        'error-callback': () => {
          if (current !== generation) return;
          token = ''; submit.disabled = true;
          status.textContent = 'Verification is unavailable. Close and reopen the form to try again.';
        }
      });
    } catch {
      if (current === generation) status.textContent = 'Verification could not load. Close and reopen the form to try again.';
    }
  }
  document.addEventListener('click', event => {
    const opener = event.target.closest('[data-waitlist-open]');
    if (!opener || dialog.open) return;
    trigger = opener; successful = false; form.hidden = false;
    status.textContent = enabled ? '' : 'Cloud waitlist signup is not available on this preview yet. You can run Hive locally today at hivecli.sh.';
    submit.textContent = 'Join Hive Cloud waitlist';
    dialog.showModal(); email.focus(); freshChallenge();
  });
  document.getElementById('waitlist-close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', () => {
    ++generation;
    request?.abort(); request = undefined; busy = false;
    form.removeAttribute('aria-busy'); email.readOnly = false;
    removeChallenge();
    if (successful) email.value = '';
    trigger?.focus();
  });
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (!enabled || busy || !token || !form.reportValidity()) return;
    busy = true; submit.disabled = true; email.readOnly = true;
    form.setAttribute('aria-busy', 'true');
    submit.textContent = 'Joining…'; status.textContent = 'Saving your place on the waitlist…';
    const current = generation;
    const controller = new AbortController(); request = controller;
    const timeout = setTimeout(() => controller.abort(), 12000);
    const submittedToken = token; token = '';
    try {
      const response = await fetch('/api/waitlist', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: email.value.trim(), token: submittedToken }),
        signal: controller.signal
      });
      const body = await response.json();
      if (current !== generation || !dialog.open) return;
      if (!response.ok || body.ok !== true) throw new Error('signup failed');
      successful = true;
      removeChallenge();
      email.value = '';
      status.textContent = 'You’re on the list. We’ll email you when Hive Cloud is ready.';
      submit.textContent = 'You’re on the list';
    } catch {
      if (current !== generation || !dialog.open) return;
      status.textContent = 'We couldn’t confirm your signup. Your email is still here. Complete the fresh verification and try again.';
    } finally {
      clearTimeout(timeout);
      if (current === generation && dialog.open) {
        busy = false; request = undefined; email.readOnly = false;
        form.removeAttribute('aria-busy');
        if (!successful) { submit.textContent = 'Join Hive Cloud waitlist'; freshChallenge(); }
      }
    }
  });
}
