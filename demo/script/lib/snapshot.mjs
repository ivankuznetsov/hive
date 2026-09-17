import { createHash } from 'node:crypto';

export const SELECTION_SCHEMA = 'hive-demo-selection';
export const SELECTION_VERSION = 1;
export const DATASET_SCHEMA = 'hive-demo-snapshot';
export const DATASET_VERSION = 1;

export const EXCLUDED_PROJECTS = Object.freeze([
  'writero', 'todero', 'webmail.sh', 'rabatafs', 'hive-private'
]);

export const PRIVATE_PROJECT_REDACTION = Object.freeze({
  pattern: '\\/home\\/[A-Za-z0-9._-]+\\/Dev\\/(?:writero|todero|webmail\\.sh|rabatafs|hive-private|writing)',
  replace: '<private-repository>',
  kind: 'private_project',
  reason: 'Paths to non-public projects are not publishable'
});

export const FORBIDDEN_PATTERNS = Object.freeze([
  ['absolute_path', /(?:\/home\/|\/Users\/|[A-Za-z]:\\\\?(?:Users|home)\\\\)/, 'local absolute path'],
  ['operator_name', /\basterio\b/, 'operator account name'],
  ['excluded_project', new RegExp(`\\b(?:${EXCLUDED_PROJECTS.map((name) => name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')})\\b`, 'i'), 'excluded project reference'],
  ['prelaunch_endpoint', /\bhivedev\.sh\b/, 'pre-launch endpoint'],
  ['secret', /\b(?:gh[pous]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----)/, 'credential or private key'],
  ['active_content', /\b(?:javascript:|vbscript:|data:text\/html)|\bon(?:error|load|click)\s*=\s*["']/i, 'executable content'],
  ['email', /\b[A-Za-z0-9._%+-]+@(?!example\.(?:com|org|net)\b)[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/, 'email address'],
  ['control_bytes', /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/, 'control bytes'],
  ['null_byte', /\u0000/, 'null byte']
]);

export function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

export function auditText(text, { allow = [] } = {}) {
  const findings = [];
  for (const [kind, pattern, description] of FORBIDDEN_PATTERNS) {
    if (allow.includes(kind)) continue;
    const match = pattern.exec(text);
    if (match) {
      findings.push({ kind, description, sample: match[0].slice(0, 80) });
    }
  }
  return findings;
}

export function auditOptionsFor(path) {
  return path.endsWith('.patch') ? { allow: ['active_content'] } : {};
}

export function validateSelection(selection) {
  const errors = [];
  if (selection.schema !== SELECTION_SCHEMA || selection.schema_version !== SELECTION_VERSION) {
    errors.push(`selection must be ${SELECTION_SCHEMA} v${SELECTION_VERSION}`);
  }
  const seen = new Set();
  const tasks = Array.isArray(selection.tasks) ? selection.tasks : [];
  if (tasks.length === 0) errors.push('selection.tasks must not be empty');
  for (const task of tasks) {
    const key = `${task.project}:${task.id}`;
    if (seen.has(key)) errors.push(`duplicate task identity ${key}`);
    seen.add(key);
    if (!['lead', 'supporting', 'active'].includes(task.role)) {
      errors.push(`${key}: role must be lead, supporting, or active`);
    }
    if (task.role === 'active') {
      if (task.outcome) errors.push(`${key}: an active example must not claim a merged outcome`);
    } else {
      const outcome = task.outcome || {};
      if (outcome.state !== 'MERGED') errors.push(`${key}: completed story requires MERGED public outcome`);
      if (!/^https:\/\/github\.com\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\/pull\/\d+$/.test(outcome.url || '')) {
        errors.push(`${key}: outcome.url must be a public pull request URL`);
      }
      if (!outcome.repository || !Number.isInteger(outcome.number)) {
        errors.push(`${key}: outcome.repository and outcome.number are required`);
      }
    }
    if (!Array.isArray(task.documents) || task.documents.length === 0) {
      errors.push(`${key}: at least one document must be selected`);
    }
  }
  for (const project of selection.projects || []) {
    if (EXCLUDED_PROJECTS.includes(project.name)) {
      errors.push(`project ${project.name} is not publishable`);
    }
  }
  const selectedProjects = new Set((selection.projects || []).map((project) => project.name));
  for (const task of tasks) {
    if (!selectedProjects.has(task.project)) errors.push(`${task.project}:${task.id} names an unselected project`);
  }
  if (!selection.digest || selection.digest.date !== '2026-09-15') {
    errors.push('digest selection must pin the real 2026-09-15 record');
  }
  if (!selection.digest?.label) {
    errors.push('digest selection must label the filtered view');
  }
  return errors;
}

export function validateDataset(dataset) {
  const errors = [];
  if (dataset.schema !== DATASET_SCHEMA || dataset.schema_version !== DATASET_VERSION) {
    errors.push(`dataset must be ${DATASET_SCHEMA} v${DATASET_VERSION}`);
  }
  const projects = new Set((dataset.projects || []).map((project) => project.name));
  for (const name of EXCLUDED_PROJECTS) {
    if (projects.has(name)) errors.push(`dataset contains excluded project ${name}`);
  }
  const tasks = dataset.tasks || [];
  const completed = tasks.filter((task) => task.role !== 'active');
  const active = tasks.filter((task) => task.role === 'active');
  for (const task of tasks) {
    if (!['lead', 'supporting', 'active'].includes(task.role)) {
      errors.push(`${task.project}:${task.id} has an invalid role`);
    }
    if (!task.path?.startsWith('data/tasks/')) errors.push(`${task.project}:${task.id} has no task data path`);
    if (task.role === 'active' && task.archived) errors.push(`${task.project}:${task.id} is active and must not be marked archived`);
  }
  if (completed.length !== 10) errors.push(`expected 10 completed stories, found ${completed.length}`);
  if (active.length !== 2) errors.push(`expected 2 active examples, found ${active.length}`);
  return errors;
}

export function validateTaskFile(task) {
  const errors = [];
  const identity = `${task.project}:${task.id}`;
  if (!task.documents?.length) errors.push(`${identity} has no documents`);
  for (const document of task.documents) {
    if (!document.path?.startsWith('documents/')) errors.push(`${document.path || 'document'}: path is not relative to the snapshot`);
    if (!document.sha256) errors.push(`${identity} document ${document.name} is missing provenance`);
  }
  if (task.role === 'active' && task.publication) {
    errors.push(`${identity} is active and must not carry publication evidence`);
  }
  if (task.role !== 'active') {
    if (task.publication?.state !== 'MERGED') errors.push(`${identity} has no merged publication evidence`);
    if (!task.publication?.merged_at) errors.push(`${identity} publication is missing merged_at`);
    if (!task.publication?.url) errors.push(`${identity} publication is missing a public URL`);
  }
  if (task.change && !['available', 'unavailable', 'truncated'].includes(task.change.state)) {
    errors.push(`${identity} change state is invalid`);
  }
  return errors;
}

export function redactText(text, redactions) {
  let output = text;
  const applied = [];
  for (const redaction of redactions || []) {
    const pattern = new RegExp(redaction.pattern, redaction.flags || 'g');
    const matches = output.match(pattern);
    if (matches) {
      output = output.replace(pattern, redaction.replace);
      applied.push({ reason: redaction.reason, matches: matches.length });
    }
  }
  return { text: output, applied };
}

export const LOCAL_PATH_REDACTION = Object.freeze({
  pattern: '(?:\\/home\\/[A-Za-z0-9._-]+\\/Dev\\/)?([A-Za-z0-9._-]+)\\.worktrees\\/[A-Za-z0-9._-]+',
  replace: '<task-worktree>',
  kind: 'local_path',
  reason: 'Local task worktree paths are not publishable'
});

export const REPO_PATH_REDACTION = Object.freeze({
  pattern: '\\/home\\/[A-Za-z0-9._-]+\\/Dev\\/([A-Za-z0-9._-]+)',
  replace: '<$1-repository>',
  kind: 'local_path',
  reason: 'Local repository paths are not publishable'
});

export const HOME_PATH_REDACTION = Object.freeze({
  pattern: '\\/home\\/[A-Za-z0-9._-]+(?:\\/[A-Za-z0-9._/@-]*)?',
  replace: '<local-path>',
  kind: 'local_path',
  reason: 'Local installation paths are not publishable'
});

export const EMAIL_REDACTION = Object.freeze({
  pattern: '\\b[A-Za-z0-9._%+-]+@(?!example\\.(?:com|org|net)\\b)[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b',
  replace: '<email>',
  kind: 'email',
  reason: 'Personal email addresses are not publishable'
});

export const PEM_REDACTION = Object.freeze({
  pattern: '-----BEGIN [A-Z ]*PRIVATE KEY( BLOCK)?-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY( BLOCK)?-----',
  replace: '<private-key-material-removed>',
  kind: 'pem',
  reason: 'Private-key material is never publishable, including test fixtures'
});

export const PEM_HEADER_REDACTION = Object.freeze({
  pattern: '-----BEGIN [A-Z ]*PRIVATE KEY( BLOCK)?-----',
  replace: '<private-key-material-removed>',
  kind: 'pem',
  reason: 'Private-key material is never publishable, including test fixtures'
});

export const AUTH_REDACTION = Object.freeze({
  pattern: '(authorization\\s*[:=]\\s*[\'"]?)(?:bearer|basic|token)\\s+[A-Za-z0-9._\\-+/=]{8,}',
  flags: 'gi',
  replace: '$1<redacted-credential>',
  kind: 'authorization',
  reason: 'Authorization header values are not publishable'
});

export const BEARER_REDACTION = Object.freeze({
  pattern: '\\bbearer\\s+[A-Za-z0-9._\\-+/=]{20,}',
  flags: 'gi',
  replace: 'Bearer <redacted-credential>',
  kind: 'authorization',
  reason: 'Bearer credential examples are redacted before publication'
});

export function defaultRedactions() {
  return [
    PRIVATE_PROJECT_REDACTION, LOCAL_PATH_REDACTION, REPO_PATH_REDACTION, HOME_PATH_REDACTION,
    PEM_REDACTION, PEM_HEADER_REDACTION, AUTH_REDACTION, BEARER_REDACTION, EMAIL_REDACTION
  ];
}
