#!/usr/bin/env node
import { readdir, readFile } from 'node:fs/promises';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { auditOptionsFor, auditText, sha256, validateDataset, validateSelection, validateTaskFile } from './lib/snapshot.mjs';

const DEFAULT_ROOT = fileURLToPath(new URL('../snapshot/', import.meta.url));

function parseArgs(argv) {
  let root = DEFAULT_ROOT;
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--root') root = argv[++index];
    else throw new Error(`unknown argument ${argv[index]}`);
  }
  return { root };
}

async function walk(directory, base = directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await walk(path, base));
    else if (entry.isFile()) files.push(relative(base, path));
  }
  return files.sort();
}

async function main() {
  const { root } = parseArgs(process.argv.slice(2));
  const findings = [];
  const files = await walk(root);

  const readText = async (path) => readFile(join(root, path), 'utf8');
  for (const path of files) {
    if (path === 'manifest.json') continue;
    const text = await readText(path);
    for (const finding of auditText(text, auditOptionsFor(path))) findings.push({ path, ...finding });
  }

  const selection = JSON.parse(await readText('selection.json'));
  for (const error of validateSelection(selection)) findings.push({ path: 'selection.json', kind: 'selection', description: error });

  const snapshot = JSON.parse(await readText('data/snapshot.json'));
  for (const error of validateDataset(snapshot)) findings.push({ path: 'data/snapshot.json', kind: 'dataset', description: error });
  for (const row of snapshot.tasks || []) {
    const task = JSON.parse(await readText(row.path));
    for (const error of validateTaskFile({ ...task, role: row.role })) {
      findings.push({ path: row.path, kind: 'dataset', description: error });
    }
    for (const document of task.documents || []) {
      await readText(document.path);
      if (document.sha256 !== sha256(await readText(document.path))) {
        findings.push({ path: document.path, kind: 'provenance', description: 'document hash does not match its task record' });
      }
    }
  }

  const manifest = JSON.parse(await readText('manifest.json'));
  for (const [path, record] of Object.entries(manifest.files || {})) {
    const text = await readText(path);
    if (sha256(text) !== record.sha256) {
      findings.push({ path, kind: 'provenance', description: 'published hash does not match the manifest' });
    }
    if (Buffer.byteLength(text) !== record.bytes) {
      findings.push({ path, kind: 'provenance', description: 'published byte count does not match the manifest' });
    }
  }

  const digest = JSON.parse(await readText('data/digest.json'));
  const publishedProjects = new Set((snapshot.projects || []).map((project) => project.name));
  for (const item of digest.items || []) {
    if (!publishedProjects.has(item.project)) {
      findings.push({ path: 'data/digest.json', kind: 'digest', description: `item from unpublished project ${item.project} is present` });
    }
  }
  if (digest.selected_project_view !== true) {
    findings.push({ path: 'data/digest.json', kind: 'digest', description: 'digest must be labelled a selected public-project view' });
  }

  if (findings.length > 0) {
    for (const finding of findings) {
      console.error(`${finding.path}: ${finding.kind}: ${finding.description}${finding.sample ? ` (${finding.sample})` : ''}`);
    }
    process.exit(1);
  }
  console.log(`Audited ${files.length} snapshot files; no forbidden content found.`);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
