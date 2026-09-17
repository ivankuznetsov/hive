#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  DATASET_SCHEMA, DATASET_VERSION, SELECTION_SCHEMA, SELECTION_VERSION, auditOptionsFor, auditText,
  defaultRedactions, redactText, sha256, validateSelection
} from './lib/snapshot.mjs';

const ROOT = fileURLToPath(new URL('../../', import.meta.url));
const SNAPSHOT = fileURLToPath(new URL('../snapshot/', import.meta.url));

function parseArgs(argv) {
  const options = {
    selection: join(SNAPSHOT, 'selection.json'),
    out: SNAPSHOT,
    projectsRoot: process.env.HIVE_PROJECTS_ROOT || join(homedir(), 'Dev'),
    hive: process.env.HIVE_BIN || 'hive',
    'private-report': process.env.HIVE_CAPTURE_REPORT || null
  };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith('--')) throw new Error(`unexpected argument ${token}`);
    const [name, inline] = token.slice(2).split('=', 2);
    if (!(name in options)) throw new Error(`unknown option --${name}`);
    options[name] = inline ?? argv[++index];
  }
  return options;
}

function run(command, args, { cwd, allowFailure = false } = {}) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  if (result.error) throw result.error;
  if (result.status !== 0 && !allowFailure) {
    throw new Error(`${command} ${args.join(' ')} failed (${result.status}): ${(result.stderr || '').trim()}`);
  }
  return result;
}

function json(command, args, options = {}) {
  const result = run(command, args, options);
  try {
    return JSON.parse(result.stdout);
  } catch (error) {
    if (options.allowFailure) return null;
    throw new Error(`${command} ${args.join(' ')} did not return JSON: ${error.message}`);
  }
}

function assertSafe(path, text, extra = []) {
  const findings = auditText(text, { allow: extra, ...auditOptionsFor(path) });
  if (findings.length > 0) {
    throw new Error(`${path} is not publishable: ${findings.map((finding) => `${finding.kind} (${finding.sample})`).join(', ')}`);
  }
}

async function writeJson(root, path, value) {
  return writeText(root, path, `${JSON.stringify(value, null, 2)}\n`);
}

async function writeText(root, path, text) {
  assertSafe(path, text);
  const target = join(root, path);
  await mkdir(dirname(target), { recursive: true });
  await writeFile(target, text);
  return { sha256: sha256(text), bytes: Buffer.byteLength(text) };
}

async function folderAge(folder, capturedAt) {
  const entries = await readdir(folder, { withFileTypes: true });
  let newest = 0;
  for (const entry of entries) {
    if (!entry.isFile()) continue;
    const info = await stat(join(folder, entry.name));
    newest = Math.max(newest, info.mtimeMs);
  }
  return Math.max(0, Math.round(capturedAt - newest / 1000));
}

function taskRowSource(archiveRows, statusRows, task) {
  const matches = [];
  const archived = archiveRows.get(`${task.project}:${task.id}`);
  if (archived) matches.push({ kind: 'archive', row: archived });
  const active = statusRows.get(`${task.project}:${task.id}`);
  if (active) matches.push({ kind: 'active', row: active });
  if (matches.length === 0) throw new Error(`${task.project}:${task.id} is not present in native projections`);
  if (matches.length > 1) {
    const folders = matches.map((match) => match.row.folder).join(', ');
    throw new Error(`${task.project}:${task.id} is ambiguous across native projections: ${folders}`);
  }
  return matches[0];
}

function documentRole(name) {
  if (name === 'task.md') return 'primary';
  if (name === 'idea.md') return 'idea';
  if (name === 'brainstorm.md') return 'brainstorm';
  if (name === 'plan.md') return 'plan';
  if (name === 'pr.md') return 'publication';
  if (name === 'artifact.md') return 'artifact';
  if (name === 'summary.md') return 'outcome';
  if (name.startsWith('reviews/')) return 'review';
  return 'supporting';
}

function displayTitle(task) {
  return task.display_name || task.slug.replace(/-[0-9a-f]{4}$/, '').replaceAll('-', ' ');
}

async function loadProjections(options) {
  const archive = json(options.hive, ['archive', '--json'], { cwd: ROOT });
  const status = json(options.hive, ['status', '--operational', '--json'], { cwd: ROOT });
  const archiveRows = new Map();
  for (const project of archive.projects || []) {
    for (const row of project.tasks || []) {
      archiveRows.set(`${project.name}:${row.id}`, { ...row, project: project.name, source: 'archive' });
    }
  }
  const statusRows = new Map();
  for (const row of status.tasks || []) {
    statusRows.set(`${row.identity.project}:${row.identity.id}`, {
      ...row, id: row.identity.id, slug: row.identity.slug, project: row.identity.project,
      folder: row.identity.folder, source: 'status'
    });
  }
  return { archive, status, archiveRows, statusRows };
}

function activeAction(row) {
  const reason = (row.reasons || [])[0] || {};
  const actionByReason = {
    wait_for_answers: 'needs_input',
    human_input: 'needs_input',
    plan_review_retry_scheduled: 'plan_review_retry',
    plan_reviewing: 'plan_reviewing'
  };
  return actionByReason[reason.code] || (row.state === 'waiting_on_you' ? 'needs_input' : 'plan_review_retry');
}

function activeReason(row) {
  return row.reason || null;
}

async function captureDocument(folder, source, redactions, out, projectDir) {
  const absolute = join(folder, source);
  if (!existsSync(absolute)) throw new Error(`selected artifact is missing: ${absolute}`);
  const original = await readFile(absolute, 'utf8');
  const { text, applied } = redactText(original, redactions);
  const name = source.startsWith('reviews/') ? source : basename(source);
  const target = `documents/${projectDir}/${name}`;
  const record = await writeText(out, target, text);
  return {
    document: { name, path: target, bytes: record.bytes, sha256: record.sha256, role: documentRole(source), format: 'markdown' },
    record,
    applied
  };
}

function verifyPublication(task) {
  if (task.role === 'active') return null;
  const api = json('gh', ['api', `repos/${task.outcome.repository}/pulls/${task.outcome.number}`], { cwd: ROOT });
  if (api.merged !== true || api.state !== 'closed') {
    throw new Error(`${task.project}:${task.id} outcome is not a merged pull request`);
  }
  if (task.outcome.merged_at && new Date(api.merged_at).toISOString() !== new Date(task.outcome.merged_at).toISOString()) {
    throw new Error(`${task.project}:${task.id} merged_at does not match the recorded public evidence`);
  }
  return {
    repository: task.outcome.repository,
    url: api.html_url,
    number: api.number,
    state: 'MERGED',
    merged_at: api.merged_at,
    merge_oid: api.merge_commit_sha,
    head_oid: api.head?.sha || null,
    base_branch: api.base?.ref || null,
    branch: api.head?.ref || null,
    authority: task.outcome.authority || 'remote_merge'
  };
}

async function captureChange(change, publication, out, projectDir, manifest, redactions) {
  if (!change || change.include !== true) return null;
  if (!publication || publication.state !== 'MERGED') {
    return { state: 'unavailable', reason: 'Public merge evidence was not confirmed at capture time.', provenance: publication || null };
  }
  const diff = run('gh', ['pr', 'diff', String(publication.number), '--repo', publication.repository], { allowFailure: true });
  if (diff.status !== 0 || !diff.stdout) {
    return { state: 'unavailable', reason: 'The public patch could not be captured; open the pull request for the full change.', provenance: publication };
  }
  const cap = change.max_bytes || 512 * 1024;
  const bytes = Buffer.from(diff.stdout);
  const truncated = bytes.byteLength > cap;
  const sliced = truncated ? bytes.subarray(0, cap).toString('utf8') : diff.stdout;
  const { text, applied } = redactText(sliced, redactions);
  const target = `changes/${projectDir}.patch`;
  const record = await writeText(out, target, text);
  manifest.files[target] = { sha256: record.sha256, bytes: record.bytes };
  for (const application of applied) manifest.redactions.push({ path: target, ...application });
  return {
    state: truncated ? 'truncated' : 'available',
    path: target,
    bytes: record.bytes,
    sha256: record.sha256,
    truncated,
    redacted: applied.length > 0,
    provenance: publication
  };
}

function sanitizeQuestion(slot) {
  return {
    n: slot.question_number,
    ordinal: slot.ordinal,
    round: slot.round,
    question: slot.text,
    answer: slot.answered ? slot.answer : null,
    answered: slot.answered === true
  };
}

async function captureTask(task, context) {
  const { options, projections, capturedAt, out, projects, manifest } = context;
  const { row, kind } = taskRowSource(projections.archiveRows, projections.statusRows, task);
  const folder = row.folder;
  const projectDir = `${task.project}-${task.id}`;
  const redactions = [...defaultRedactions(), ...(task.redactions || [])];
  const documents = [];
  const redactionRecords = [];

  for (const source of task.documents) {
    const { document, record, applied } = await captureDocument(folder, source, redactions, out, projectDir);
    documents.push(document);
    manifest.files[document.path] = { sha256: record.sha256, bytes: record.bytes };
    for (const application of applied) {
      redactionRecords.push({ path: document.path, ...application });
    }
  }
  const primaryDocument = documents.find((document) => document.role === 'primary') || documents.find((document) => document.role === 'plan') || null;

  const workspace = json(options.hive, ['task', String(task.id), '--project', task.project, '--json'], { cwd: ROOT });
  const questions = [];
  if (kind === 'active') {
    const inventory = json(options.hive, ['answer', String(task.id), '--project', task.project, '--json'], { cwd: ROOT, allowFailure: true });
    if (inventory && inventory.ok && Array.isArray(inventory.slots)) {
      questions.push(...inventory.slots.map(sanitizeQuestion));
    }
  }

  const publication = verifyPublication(task);
  const change = await captureChange(task.change, publication, out, projectDir, manifest, redactions);
  const archived = kind === 'archive';

  const taskJson = {
    schema: 'hive-demo-task',
    schema_version: 1,
    project: task.project,
    repository: projects.get(task.project).repository,
    id: task.id,
    slug: row.slug,
    title: task.title || row.display_name || displayTitle({ slug: row.slug }),
    role: task.role,
    workflow: row.workflow || 'coding',
    stage: archived ? row.stage : row.position?.stage || null,
    archived,
    action: archived ? row.action : activeAction(row),
    action_label: archived ? row.action_label : null,
    reason: archived ? null : activeReason(row),
    unanswered_questions: questions.filter((question) => !question.answered).length,
    headline: workspace.headline || null,
    status: workspace.status || null,
    captured_at: capturedAt,
    observed_at: archived ? (row.closure?.confirmed_at || null) : capturedAt,
    age_seconds: await folderAge(folder, Date.parse(capturedAt) / 1000),
    documents,
    primary_document: primaryDocument ? primaryDocument.path : null,
    publication,
    change,
    questions,
    source: { kind: 'native-task-workspace', schema: 'hive-task-workspace', schema_version: 2 }
  };
  const taskPath = `data/tasks/${projectDir}.json`;
  manifest.files[taskPath] = await writeJson(out, taskPath, taskJson);
  return { taskJson, redactionRecords, marker: archived ? (row.marker || null) : (row.position?.marker || null) };
}

function workflowPackage(workflow, hiveStatePath) {
  if (workflow.origin !== 'managed' || !workflow.source_commit || !hiveStatePath) return null;
  const manifestPath = join(hiveStatePath, 'workflows', workflow.name, 'versions', workflow.source_commit, 'manifest.yml');
  if (!existsSync(manifestPath)) return null;
  const result = spawnSync('ruby', ['-ryaml', '-rjson', '-e', 'puts JSON.generate(YAML.safe_load(STDIN.read, aliases: true))'], {
    input: readFileSync(manifestPath, 'utf8'), encoding: 'utf8'
  });
  if (result.status !== 0) throw new Error(`could not read ${manifestPath}: ${result.stderr}`);
  const manifest = JSON.parse(result.stdout);
  const permissions = manifest.permissions || {};
  return {
    description: manifest.description || null,
    author: manifest.author || null,
    license: manifest.license || null,
    hive_min_version: manifest.hive_min_version || null,
    source: manifest.source || null,
    permissions: {
      risk: permissions.risk || null,
      capabilities: permissions.capabilities || [],
      network_hosts: permissions.network_hosts || [],
      filesystem_read: permissions.filesystem_read || [],
      filesystem_write: permissions.filesystem_write || [],
      secrets: permissions.secrets || []
    }
  };
}

async function captureWorkflows(selection, options, out, manifest, projections) {
  const project = selection.workflows.project;
  const cwd = join(options.projectsRoot, project);
  const projectEntry = (projections.archive.projects || []).find((candidate) => candidate.name === project) || {};
  const listed = json(options.hive, ['workflow', 'list', '--json'], { cwd });
  const exclude = new Set(selection.workflows.exclude || []);
  const workflows = (listed.workflows || []).filter((workflow) => !exclude.has(workflow.name)).map((workflow) => ({
    ...workflow,
    package: workflowPackage(workflow, projectEntry.hive_state_path)
  }));
  const payload = {
    schema: 'hive-demo-workflows',
    schema_version: 1,
    project,
    captured_at: new Date().toISOString(),
    excluded: [...exclude],
    workflows
  };
  manifest.files['data/workflows.json'] = await writeJson(out, 'data/workflows.json', payload);
  return payload;
}

async function captureModules(selection, options, out, manifest) {
  const project = selection.modules.project;
  const cwd = join(options.projectsRoot, project);
  const listed = json(options.hive, ['module', 'list', '--json'], { cwd });
  const exclude = new Set(selection.modules.exclude || []);
  const payload = {
    schema: 'hive-demo-modules',
    schema_version: 1,
    project,
    captured_at: new Date().toISOString(),
    excluded: [...exclude],
    modules: (listed.modules || []).filter((hiveModule) => !exclude.has(hiveModule.name))
  };
  manifest.files['data/modules.json'] = await writeJson(out, 'data/modules.json', payload);
  return payload;
}

async function capturePatrol(selection, options, out, manifest) {
  const { project, architecture_job: architectureJob, ordinary_findings: ordinaryFindings } = selection.patrol;
  const cwd = join(options.projectsRoot, project);
  const findings = json(options.hive, ['patrol', project, '--list', '--json'], { cwd });
  const selected = new Map((findings.findings || []).map((finding) => [finding.id, finding]));
  const ordinaryItems = ordinaryFindings.map((id) => {
    const finding = selected.get(id);
    if (!finding) throw new Error(`selected Patrol finding is missing: ${id}`);
    return {
      id: finding.id,
      feature_id: finding.feature_id,
      category: finding.category,
      severity: finding.severity,
      confidence: finding.confidence,
      title: finding.title,
      description: finding.description,
      lifecycle_state: finding.lifecycle_state,
      lifecycle_updated_at: finding.lifecycle_updated_at,
      target_sha: finding.target_sha || null,
      source_state: 'active'
    };
  });
  const job = json(options.hive, ['refactor-patrol', project, '--show', architectureJob, '--json'], { cwd }).job;
  const dispositions = job.dispositions || {};
  const theses = [];
  for (const route of ['fix', 'discuss']) {
    for (const item of dispositions[route] || []) {
      if (theses.length >= selection.patrol.selected_theses) break;
      theses.push({
        id: item.id,
        route,
        feature_id: item.feature_id,
        problem: item.thesis?.problem || null,
        proposed_refactor: item.thesis?.proposed_refactor || null
      });
    }
  }
  const actions = (job.actions || []).map((action) => ({
    thesis_id: action.thesis_id,
    kind: action.kind,
    outcome: action.outcome,
    terminal: action.terminal === true,
    updated_at: action.updated_at
  }));
  const payload = {
    schema: 'hive-demo-patrol',
    schema_version: 1,
    project,
    captured_at: new Date().toISOString(),
    ordinary: {
      state: 'captured',
      source_total: findings.count,
      source_counts: findings.counts,
      truncated_source: findings.truncated === true,
      selected_count: ordinaryItems.length,
      items: ordinaryItems,
      last_run_at: findings.last_run_at || null
    },
    architecture: {
      state: job.state,
      job_id: job.job_id,
      source: job.source,
      counts: job.counts,
      selected_theses: theses,
      actions,
      review_errors: job.review_errors || [],
      zero_reason: job.zero_reason || null,
      updated_at: job.updated_at
    }
  };
  manifest.files['data/patrol.json'] = await writeJson(out, 'data/patrol.json', payload);
  return payload;
}

async function captureDigest(selection, options, out, manifest) {
  const selected = new Set(selection.projects.map((project) => project.name));
  const digest = json(options.hive, ['digest', '--date', selection.digest.date, '--json'], { cwd: ROOT });
  if (digest.local_date !== selection.digest.date) throw new Error(`digest date mismatch: ${digest.local_date}`);
  const sourceItems = digest.items || [];
  const items = sourceItems.filter((item) => selected.has(item.project));
  const projects = (digest.projects || []).filter((project) => selected.has(project.name));
  const payload = {
    ...digest,
    document: null,
    items,
    projects,
    attention: [],
    amendments: [],
    previous_date: null,
    next_date: null,
    stale: false,
    selected_project_view: true,
    view_label: selection.digest.label,
    filtered_item_count: sourceItems.length - items.length,
    source_total_items: sourceItems.length
  };
  for (const key of ['web_url', 'repository_stats', 'precoverage', 'gaps', 'cutover']) {
    if (key in payload) delete payload[key];
  }
  manifest.files['data/digest.json'] = await writeJson(out, 'data/digest.json', payload);
  return payload;
}

async function captureRepos(selection, options, out, manifest) {
  const repos = [];
  for (const project of selection.projects) {
    const api = json('gh', ['api', `repos/${project.repository}`], { cwd: ROOT });
    const capturedHead = run('git', ['-C', join(options.projectsRoot, project.name), 'rev-parse', 'HEAD'], { allowFailure: true });
    repos.push({
      name: project.name,
      repository: project.repository,
      url: api.html_url,
      description: api.description || null,
      language: api.language || null,
      license: api.license ? { spdx_id: api.license.spdx_id, name: api.license.name } : null,
      private: api.private === true,
      archived: api.archived === true,
      default_branch: api.default_branch || null,
      pushed_at: api.pushed_at || null,
      stars: api.stargazers_count ?? null,
      captured_head: capturedHead.status === 0 ? capturedHead.stdout.trim() : null
    });
  }
  const payload = { schema: 'hive-demo-repos', schema_version: 1, captured_at: new Date().toISOString(), repos };
  manifest.files['data/repos.json'] = await writeJson(out, 'data/repos.json', payload);
  return payload;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const selection = JSON.parse(await readFile(options.selection, 'utf8'));
  const selectionErrors = validateSelection(selection);
  if (selectionErrors.length > 0) throw new Error(`selection is invalid:\n- ${selectionErrors.join('\n- ')}`);

  const projections = await loadProjections(options);
  const projects = new Map(selection.projects.map((project) => [project.name, project]));
  for (const task of selection.tasks) {
    if (!projects.has(task.project)) throw new Error(`task ${task.project}:${task.id} names an unselected project`);
  }

  const capturedAt = new Date().toISOString();
  const manifest = {
    schema: 'hive-demo-snapshot-manifest',
    schema_version: 1,
    captured_at: capturedAt,
    ui_sha: selection.captured_from.ui_sha,
    hive_version: selection.captured_from.hive_version,
    source: selection.captured_from.source,
    files: {},
    redactions: [],
    omissions: []
  };

  await rm(join(options.out, 'data'), { recursive: true, force: true });
  await rm(join(options.out, 'documents'), { recursive: true, force: true });
  await rm(join(options.out, 'changes'), { recursive: true, force: true });

  const taskRows = [];
  const context = { options, projections, capturedAt, out: options.out, projects, manifest };
  for (const task of selection.tasks) {
    const { taskJson, redactionRecords, marker } = await captureTask(task, context);
    manifest.redactions.push(...redactionRecords);
    taskRows.push({
      project: taskJson.project,
      id: taskJson.id,
      slug: taskJson.slug,
      title: taskJson.title,
      role: taskJson.role,
      workflow: taskJson.workflow,
      stage: taskJson.stage,
      marker,
      action: taskJson.action,
      action_label: taskJson.action_label,
      archived: taskJson.archived,
      age_seconds: taskJson.age_seconds,
      reason: taskJson.reason,
      unanswered_questions: taskJson.questions.filter((question) => !question.answered).length,
      path: `data/tasks/${taskJson.project}-${taskJson.id}.json`,
      repository: taskJson.repository
    });
  }

  const status = {
    schema: 'hive-demo-status',
    schema_version: 1,
    captured_at: capturedAt,
    ui_sha: selection.captured_from.ui_sha,
    source: 'Frozen native projections captured from an operator installation; no live connection is used by the demo.',
    projects: selection.projects.map((project) => ({
      name: project.name, repository: project.repository, url: project.url, license: project.license, visibility: project.visibility
    })),
    scope: {
      project_count: selection.projects.length,
      completed_count: taskRows.filter((row) => row.role !== 'active').length,
      active_count: taskRows.filter((row) => row.role === 'active').length
    },
    active: taskRows.filter((row) => row.role === 'active'),
    archived: taskRows.filter((row) => row.role !== 'active')
  };
  manifest.files['data/status.json'] = await writeJson(options.out, 'data/status.json', status);

  await captureWorkflows(selection, options, options.out, manifest, projections);
  await captureModules(selection, options, options.out, manifest);
  await capturePatrol(selection, options, options.out, manifest);
  await captureDigest(selection, options, options.out, manifest);
  await captureRepos(selection, options, options.out, manifest);

  const dataset = {
    schema: DATASET_SCHEMA,
    schema_version: DATASET_VERSION,
    captured_at: capturedAt,
    ui_sha: selection.captured_from.ui_sha,
    projects: status.projects,
    scope: status.scope,
    tasks: taskRows
  };
  manifest.files['data/snapshot.json'] = await writeJson(options.out, 'data/snapshot.json', dataset);

  manifest.omissions = selection.omissions || [];
  await writeJson(options.out, 'manifest.json', manifest);

  const audit = spawnSync(process.execPath, [join(dirname(fileURLToPath(import.meta.url)), 'audit_snapshot.mjs'), '--root', options.out], { encoding: 'utf8' });
  if (audit.status !== 0) throw new Error(`capture failed the publication audit:\n${audit.stdout}${audit.stderr}`);

  if (options['private-report']) {
    await writeFile(resolve(options['private-report']), `${JSON.stringify({
      selection: options.selection,
      captured_at: capturedAt,
      tasks: taskRows,
      redactions: manifest.redactions
    }, null, 2)}\n`);
  }
  console.log(`Captured ${taskRows.length} tasks across ${status.projects.length} projects at ${capturedAt}.`);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
