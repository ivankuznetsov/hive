#!/usr/bin/env node
import { readdir, readFile } from 'node:fs/promises';
import { join, relative, resolve, sep } from 'node:path';
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
  const contents = new Map();
  const read = async (path) => {
    const absolute = resolve(root, path);
    if (!absolute.startsWith(`${resolve(root)}${sep}`)) throw new Error(`snapshot path escapes the root: ${path}`);
    if (!contents.has(path)) contents.set(path, await readFile(absolute, 'utf8'));
    return contents.get(path);
  };

  const files = await walk(root);
  for (const path of files) {
    if (path === 'manifest.json') continue;
    for (const finding of auditText(await read(path), auditOptionsFor(path))) findings.push({ path, ...finding });
  }

  const selection = JSON.parse(await read('selection.json'));
  for (const error of validateSelection(selection)) findings.push({ path: 'selection.json', kind: 'selection', description: error });

  const snapshot = JSON.parse(await read('data/snapshot.json'));
  for (const error of validateDataset(snapshot)) findings.push({ path: 'data/snapshot.json', kind: 'dataset', description: error });
  for (const row of snapshot.tasks || []) {
    const task = JSON.parse(await read(row.path));
    for (const error of validateTaskFile({ ...task, role: row.role })) {
      findings.push({ path: row.path, kind: 'dataset', description: error });
    }
    for (const document of task.documents || []) {
      if (document.sha256 !== sha256(await read(document.path))) {
        findings.push({ path: document.path, kind: 'provenance', description: 'document hash does not match its task record' });
      }
    }
  }

  const manifest = JSON.parse(await read('manifest.json'));
  for (const [path, record] of Object.entries(manifest.files || {})) {
    const text = await read(path);
    if (sha256(text) !== record.sha256) {
      findings.push({ path, kind: 'provenance', description: 'published hash does not match the manifest' });
    }
    if (Buffer.byteLength(text) !== record.bytes) {
      findings.push({ path, kind: 'provenance', description: 'published byte count does not match the manifest' });
    }
  }

  const digest = JSON.parse(await read('data/digest.json'));
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
