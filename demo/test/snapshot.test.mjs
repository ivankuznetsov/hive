import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  auditOptionsFor, auditText, redactText, sha256, validateDataset, validateSelection, validateTaskFile
} from '../script/lib/snapshot.mjs';

const SNAPSHOT = fileURLToPath(new URL('../snapshot/', import.meta.url));
const readJson = async (path) => JSON.parse(await readFile(join(SNAPSHOT, path), 'utf8'));

const baseSelection = () => ({
  schema: 'hive-demo-selection',
  schema_version: 1,
  captured_from: { ui_sha: 'a'.repeat(40), hive_version: '0.7.4' },
  projects: [{ name: 'hive', repository: 'ivankuznetsov/hive', url: 'https://github.com/ivankuznetsov/hive', visibility: 'public' }],
  tasks: [{
    project: 'hive', id: 1, role: 'lead', title: 'Example',
    outcome: { repository: 'ivankuznetsov/hive', number: 1, url: 'https://github.com/ivankuznetsov/hive/pull/1', state: 'MERGED' },
    documents: ['idea.md']
  }],
  digest: { date: '2026-09-15', label: 'Selected public-project view' }
});

test('an unmerged pull request cannot become a merged outcome', () => {
  const selection = baseSelection();
  selection.tasks[0].outcome.state = 'OPEN';
  assert.match(validateSelection(selection).join('\n'), /MERGED/);
});

test('a duplicate task identity cannot silently select the wrong source', () => {
  const selection = baseSelection();
  selection.tasks.push({ ...selection.tasks[0], role: 'active', outcome: undefined });
  assert.match(validateSelection(selection).join('\n'), /duplicate task identity/);
});

test('an excluded project cannot enter the published selection', () => {
  const selection = baseSelection();
  selection.projects.push({ name: 'writero', repository: 'ivankuznetsov/writero', visibility: 'private' });
  assert.match(validateSelection(selection).join('\n'), /not publishable/);
});

test('an unselected task cannot be attached to an unselected project', () => {
  const selection = baseSelection();
  selection.tasks[0].project = 'other';
  assert.match(validateSelection(selection).join('\n'), /unselected project|not publishable/);
});

test('a merged dataset requires ten completed stories, two active examples, and merged evidence', () => {
  const dataset = {
    schema: 'hive-demo-snapshot', schema_version: 1,
    projects: [{ name: 'hive' }],
    tasks: [
      { project: 'hive', id: 1, role: 'lead', path: 'data/tasks/hive-1.json', archived: true },
      { project: 'hive', id: 2, role: 'active', path: 'data/tasks/hive-2.json', archived: false }
    ]
  };
  const errors = validateDataset(dataset).join('\n');
  assert.match(errors, /expected 10 completed stories/);
  assert.match(errors, /expected 2 active examples/);
});

test('a task record cannot mix active status with publication evidence', () => {
  const task = {
    project: 'hive', id: 2, role: 'active',
    documents: [{ name: 'idea.md', path: 'documents/hive-2/idea.md', sha256: 'a'.repeat(64) }],
    publication: { state: 'MERGED' }
  };
  assert.match(validateTaskFile(task).join('\n'), /must not carry publication evidence/);
});

test('a completed task record must carry merged publication evidence', () => {
  const task = {
    project: 'hive', id: 1, role: 'supporting',
    documents: [{ name: 'plan.md', path: 'documents/hive-1/plan.md', sha256: 'a'.repeat(64) }],
    publication: { state: 'MERGED', url: 'https://github.com/ivankuznetsov/hive/pull/1' }
  };
  assert.match(validateTaskFile(task).join('\n'), /missing merged_at/);
});

test('hidden local paths and tokens are rejected in documents', () => {
  assert.ok(auditText('see /home/operator/Dev/hive/.hive-state').length > 0);
  assert.ok(auditText(`token ghp_${'a'.repeat(36)}`).length > 0);
  assert.ok(auditText('contact person@real.example').length > 0);
  assert.ok(auditText('the writero project').length > 0);
});

test('example.com fixtures and patch source code remain publishable', () => {
  assert.equal(auditText('alice@example.com').length, 0);
  const patch = 'javascript:alert(1)\nconst onError = handler;';
  assert.equal(auditText(patch, auditOptionsFor('changes/hive-1.patch')).length, 0);
  assert.ok(auditText(patch).length > 0);
});

test('redactions replace text and record the match count', () => {
  const { text, applied } = redactText('a /home/operator/Dev/hive and /home/operator/Dev/hive', [
    { pattern: '\\/home\\/operator\\/Dev\\/hive', replace: '<local-path>', reason: 'path' }
  ]);
  assert.equal(text, 'a <local-path> and <local-path>');
  assert.deepEqual(applied, [{ reason: 'path', matches: 2 }]);
});

test('the checked-in snapshot matches its own provenance manifest', async () => {
  const manifest = await readJson('manifest.json');
  for (const [path, record] of Object.entries(manifest.files)) {
    const text = await readFile(join(SNAPSHOT, path), 'utf8');
    assert.equal(sha256(text), record.sha256, `${path} hash`);
    assert.equal(Buffer.byteLength(text), record.bytes, `${path} size`);
  }
});

test('the manifest lists every checked-in snapshot file', async () => {
  const manifest = await readJson('manifest.json');
  const walk = async (directory) => {
    const entries = await readdir(directory, { withFileTypes: true });
    const files = [];
    for (const entry of entries) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) files.push(...await walk(path));
      else files.push(relative(SNAPSHOT, path));
    }
    return files;
  };
  const walked = (await walk(SNAPSHOT)).filter((path) => !['manifest.json', 'selection.json'].includes(path));
  assert.deepEqual(Object.keys(manifest.files).sort(), walked.sort());
});

test('the checked-in snapshot carries ten verified stories and two active examples', async () => {
  const dataset = await readJson('data/snapshot.json');
  assert.deepEqual(validateDataset(dataset), []);
  const completed = dataset.tasks.filter((task) => task.role !== 'active');
  const active = dataset.tasks.filter((task) => task.role === 'active');
  assert.equal(completed.length, 10);
  assert.equal(active.length, 2);
  for (const row of dataset.tasks) {
    const task = await readJson(row.path);
    assert.deepEqual(validateTaskFile({ ...task, role: row.role }), []);
    for (const document of task.documents) {
      const text = await readFile(join(SNAPSHOT, document.path), 'utf8');
      assert.equal(sha256(text), document.sha256, `${document.path} provenance`);
    }
  }
});

test('the checked-in snapshot never names an unpublished project', async () => {
  const dataset = await readJson('data/snapshot.json');
  const publicNames = new Set(dataset.projects.map((project) => project.name));
  const digest = await readJson('data/digest.json');
  for (const item of digest.items) assert.ok(publicNames.has(item.project));
  const digestProjects = new Set(digest.projects.map((project) => project.name));
  for (const item of digest.items) assert.ok(digestProjects.has(item.project));
});
