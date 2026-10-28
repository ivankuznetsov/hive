export async function copyTaskReference(button) {
  const container = button.closest('.task-reference');
  const code = container?.querySelector('code');
  const status = container?.querySelector('[role="status"]');
  if (!code || !status) return;
  try {
    await navigator.clipboard.writeText(code.textContent);
    status.textContent = 'Copied';
  } catch {
    const range = document.createRange();
    range.selectNodeContents(code);
    const selection = window.getSelection();
    selection.removeAllRanges(); selection.addRange(range);
    code.focus();
    status.textContent = 'Select and copy the reference.';
  }
}
