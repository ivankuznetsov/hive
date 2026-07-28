import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const [
  mode,
  rootInput,
  configPathInput,
  approvalsPathInput,
  workspaceInput,
  receiptPath,
  expectedVersion,
  descriptorInput,
  instructionDirInput,
] = process.argv.slice(2);
const root = fs.realpathSync(rootInput);
const configPath = fs.realpathSync(configPathInput);
const approvalsPath = fs.realpathSync(approvalsPathInput);
const workspace = fs.realpathSync(workspaceInput);
process.env.OPENCLAW_CONFIG_PATH = configPath;
process.env.OPENCLAW_STATE_DIR = path.dirname(approvalsPath);

const sha256 = (value) =>
  crypto.createHash("sha256").update(value).digest("hex");
const driverSha256 = sha256(fs.readFileSync(process.argv[1]));
const fileState = (target) => {
  if (!fs.existsSync(target)) return { exists: false };
  const stat = fs.lstatSync(target);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    return { exists: true, type: "non_regular" };
  }
  const bytes = fs.readFileSync(target);
  return {
    exists: true,
    type: "file",
    size: bytes.length,
    sha256: sha256(bytes),
  };
};
const inside = (target, base) => {
  const relative = path.relative(base, target);
  return (
    relative !== "" &&
    relative !== ".." &&
    !relative.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relative)
  );
};
const shellQuote = (value) => `'${String(value).replaceAll("'", "'\\''")}'`;
const textResult = (result) =>
  (result?.content ?? [])
    .filter((item) => item?.type === "text")
    .map((item) => item.text ?? "")
    .join("\n");

const packageRoot = fs.realpathSync(path.join(root, "node_modules", "openclaw"));
const packageJson = JSON.parse(
  fs.readFileSync(path.join(packageRoot, "package.json"), "utf8"),
);
if (packageJson.name !== "openclaw" || packageJson.version !== expectedVersion) {
  throw new Error("pinned OpenClaw package identity changed");
}
const requireFromInstall = createRequire(path.join(root, "package.json"));
const exportSpecifiers = {
  config_schema: "openclaw/plugin-sdk/config-schema",
  agent_harness: "openclaw/plugin-sdk/agent-harness",
};
const resolvedExports = Object.fromEntries(
  Object.entries(exportSpecifiers).map(([key, specifier]) => {
    const resolved = fs.realpathSync(requireFromInstall.resolve(specifier));
    if (!inside(resolved, packageRoot)) {
      throw new Error(`public OpenClaw export escaped package root: ${specifier}`);
    }
    return [key, resolved];
  }),
);
const { OpenClawSchema } = await import(
  pathToFileURL(resolvedExports.config_schema).href
);
const { createOpenClawCodingTools } = await import(
  pathToFileURL(resolvedExports.agent_harness).href
);
if (
  typeof OpenClawSchema?.parse !== "function" ||
  typeof createOpenClawCodingTools !== "function"
) {
  throw new Error("public OpenClaw native-tool exports are unavailable");
}

const rawConfig = JSON.parse(fs.readFileSync(configPath, "utf8"));
const config = OpenClawSchema.parse(rawConfig);
const primary = config?.agents?.defaults?.model?.primary;
const slash = typeof primary === "string" ? primary.indexOf("/") : -1;
if (slash <= 0 || slash === primary.length - 1) {
  throw new Error("OpenClaw primary model identity is invalid");
}
const tools = createOpenClawCodingTools({
  agentId: "main",
  cwd: workspace,
  workspaceDir: workspace,
  config,
  modelProvider: primary.slice(0, slash),
  modelId: primary.slice(slash + 1),
  oneShotCliRun: true,
  sessionKey: "agent:main:hive-native-proof",
  sessionId: "hive-native-proof",
  toolConstructionPlan: {
    includeBaseCodingTools: true,
    includeShellTools: true,
    includeChannelTools: false,
    includeOpenClawTools: false,
    includePluginTools: false,
  },
});
const expectedTools = ["apply_patch", "edit", "exec", "read", "write"];
const effectiveTools = tools.map((tool) => tool.name).sort();
if (
  JSON.stringify(effectiveTools) !== JSON.stringify(expectedTools) ||
  tools.some((tool) => typeof tool.execute !== "function")
) {
  throw new Error("effective callable OpenClaw tool surface changed");
}
const byName = Object.fromEntries(tools.map((tool) => [tool.name, tool]));
const approvals = JSON.parse(fs.readFileSync(approvalsPath, "utf8"));
const execAllowlist =
  approvals?.agents?.main?.allowlist?.map((row) => row.pattern) ?? [];
const gateway = path.join(config.tools.exec.pathPrepend[0], "hive");
if (
  execAllowlist.length !== 1 ||
  fs.realpathSync(execAllowlist[0]) !== fs.realpathSync(gateway)
) {
  throw new Error("OpenClaw exec approval identity changed");
}

const successReceipt = async (id, toolName, operation, input, verify) => {
  const before = verify.before();
  const result = await byName[toolName].execute(`hive-${id}`, input);
  const after = verify.after();
  if (!verify.valid(result, before, after)) {
    throw new Error(`native tool success control failed: ${id}`);
  }
  return {
    id,
    tool: toolName,
    operation,
    expected_decision: "succeeded",
    decision: "succeeded",
    mutation_observed:
      before.sha256 !== after.sha256 || before.exists !== after.exists,
  };
};
const deniedReceipt = async (id, toolName, operation, input, verify) => {
  const before = verify.before();
  let decision = "succeeded";
  let errorDigest = null;
  try {
    await byName[toolName].execute(`hive-${id}`, input);
  } catch (error) {
    decision = "denied";
    errorDigest = sha256(String(error?.message ?? error));
  }
  const after = verify.after();
  const mutationObserved = JSON.stringify(before) !== JSON.stringify(after);
  if (decision !== "denied" || mutationObserved || !verify.valid(before, after)) {
    throw new Error(`native tool denial control failed: ${id}`);
  }
  return {
    id,
    tool: toolName,
    operation,
    expected_decision: "denied",
    decision,
    mutation_observed: mutationObserved,
    error_sha256: errorDigest,
  };
};
const noMutation = (target) => ({
  before: () => fileState(target),
  after: () => fileState(target),
  valid: (before, after) => JSON.stringify(before) === JSON.stringify(after),
});

const runtimeSource =
  packageJson.hiveProofFixture === true
    ? "public-export-contract-fixture"
    : "openclaw-exact-runtime";
const runtimeContract = {
  name: packageJson.name,
  version: packageJson.version,
};

if (mode === "probe") {
  const receipts = [];
  const insideFile = path.join(
    workspace,
    ".hive-openclaw-native-surface.txt",
  );
  if (fs.existsSync(insideFile)) {
    throw new Error("inside native-tool control already exists");
  }
  receipts.push(
    await successReceipt(
      "inside_write",
      "write",
      "create workspace file",
      { path: insideFile, content: "alpha\n" },
      {
        before: () => fileState(insideFile),
        after: () => fileState(insideFile),
        valid: (_result, before, after) =>
          before.exists === false &&
          after.exists === true &&
          fs.readFileSync(insideFile, "utf8") === "alpha\n",
      },
    ),
  );
  receipts.push(
    await successReceipt(
      "inside_read",
      "read",
      "read workspace file",
      { path: insideFile },
      {
        before: () => fileState(insideFile),
        after: () => fileState(insideFile),
        valid: (result, before, after) =>
          JSON.stringify(before) === JSON.stringify(after) &&
          textResult(result).includes("alpha"),
      },
    ),
  );
  receipts.push(
    await successReceipt(
      "inside_edit",
      "edit",
      "edit workspace file",
      {
        path: insideFile,
        edits: [{ oldText: "alpha", newText: "beta" }],
      },
      {
        before: () => fileState(insideFile),
        after: () => fileState(insideFile),
        valid: (_result, before, after) =>
          before.sha256 !== after.sha256 &&
          fs.readFileSync(insideFile, "utf8") === "beta\n",
      },
    ),
  );
  receipts.push(
    await successReceipt(
      "inside_apply_patch",
      "apply_patch",
      "patch workspace file",
      {
        input:
          "*** Begin Patch\n" +
          "*** Update File: .hive-openclaw-native-surface.txt\n" +
          "@@\n-beta\n+gamma\n" +
          "*** End Patch\n",
      },
      {
        before: () => fileState(insideFile),
        after: () => fileState(insideFile),
        valid: (_result, before, after) =>
          before.sha256 !== after.sha256 &&
          fs.readFileSync(insideFile, "utf8") === "gamma\n",
      },
    ),
  );

  const outsideRoot = path.join(
    path.dirname(workspace),
    "openclaw-native-negative-controls",
  );
  if (fs.existsSync(outsideRoot)) {
    throw new Error("outside native-tool control root already exists");
  }
  fs.mkdirSync(outsideRoot, { mode: 0o700 });
  const outsideWrite = path.join(outsideRoot, "write.txt");
  const outsideEdit = path.join(outsideRoot, "edit.txt");
  const outsidePatch = path.join(outsideRoot, "patch.txt");
  const outsideRead = path.join(outsideRoot, "read.txt");
  fs.writeFileSync(outsideEdit, "unchanged-edit\n", { mode: 0o600 });
  fs.writeFileSync(outsidePatch, "unchanged-patch\n", { mode: 0o600 });
  fs.writeFileSync(outsideRead, "ordinary-sibling-read\n", { mode: 0o600 });
  receipts.push(
    await deniedReceipt(
      "outside_write",
      "write",
      "write outside workspace",
      { path: outsideWrite, content: "must-not-exist\n" },
      noMutation(outsideWrite),
    ),
  );
  receipts.push(
    await deniedReceipt(
      "outside_edit",
      "edit",
      "edit outside workspace",
      {
        path: outsideEdit,
        edits: [{ oldText: "unchanged-edit", newText: "changed" }],
      },
      noMutation(outsideEdit),
    ),
  );
  receipts.push(
    await deniedReceipt(
      "outside_apply_patch",
      "apply_patch",
      "patch outside workspace",
      {
        input:
          "*** Begin Patch\n" +
          `*** Update File: ${path.relative(workspace, outsidePatch)}\n` +
          "@@\n-unchanged-patch\n+changed\n" +
          "*** End Patch\n",
      },
      noMutation(outsidePatch),
    ),
  );

  let outsideReadDecision = "succeeded";
  try {
    await byName.read.execute("hive-outside-read-caveat", {
      path: outsideRead,
    });
  } catch {
    outsideReadDecision = "denied";
  }
  const outsideReadCaveat = {
    ordinary_sibling_decision: outsideReadDecision,
    global_denial_claimed: false,
    caveat:
      "OpenClaw beta.2 may admit configured read-only skill roots outside the workspace",
  };

  receipts.push(
    await successReceipt(
      "exec_hive_version",
      "exec",
      "run approved Hive gateway",
      { command: "hive version", workdir: workspace, yieldMs: 10_000 },
      {
        before: () => ({
          exists: true,
          sha256: sha256("hive version"),
        }),
        after: () => ({
          exists: true,
          sha256: sha256("hive version"),
        }),
        valid: (result) => textResult(result).trim().length > 0,
      },
    ),
  );
  const outsideTouch = path.join(outsideRoot, "absolute-touch");
  const outsideRedirect = path.join(outsideRoot, "redirect");
  const outsideChain = path.join(outsideRoot, "chained-touch");
  receipts.push(
    await deniedReceipt(
      "exec_absolute_touch",
      "exec",
      "absolute executable outside effect",
      {
        command: `/usr/bin/touch ${shellQuote(outsideTouch)}`,
        workdir: workspace,
        yieldMs: 10_000,
      },
      noMutation(outsideTouch),
    ),
  );
  receipts.push(
    await deniedReceipt(
      "exec_redirection",
      "exec",
      "shell redirection outside effect",
      {
        command: `hive version > ${shellQuote(outsideRedirect)}`,
        workdir: workspace,
        yieldMs: 10_000,
      },
      noMutation(outsideRedirect),
    ),
  );
  receipts.push(
    await deniedReceipt(
      "exec_chained_touch",
      "exec",
      "chained outside executable effect",
      {
        command: `hive version; /usr/bin/touch ${shellQuote(outsideChain)}`,
        workdir: workspace,
        yieldMs: 10_000,
      },
      noMutation(outsideChain),
    ),
  );
  receipts.push({
    id: "prohibited_web_fetch",
    tool: "web_fetch",
    operation: "network fetch",
    expected_decision: "denied",
    decision: effectiveTools.includes("web_fetch") ? "succeeded" : "denied",
    mutation_observed: false,
  });

  const unauthorizedEffects = receipts
    .filter(
      (row) =>
        row.expected_decision === "denied" &&
        (row.decision !== "denied" || row.mutation_observed !== false),
    )
    .map((row) => ({
      surface: row.tool,
      operation: row.operation,
      control_id: row.id,
    }));
  if (unauthorizedEffects.length > 0) {
    throw new Error("unauthorized native-tool effect was observed");
  }
  const payload = {
    schema: "hive-openclaw-effective-policy",
    schema_version: 2,
    source: runtimeSource,
    proof_mode: "direct_native_tool_surface",
    driver_sha256: driverSha256,
    runtime_package: runtimeContract,
    public_exports: exportSpecifiers,
    workspace,
    effective_tools: effectiveTools,
    workspace_only: config?.tools?.fs?.workspaceOnly,
    apply_patch_workspace_only:
      config?.tools?.exec?.applyPatch?.workspaceOnly,
    elevated_enabled: config?.tools?.elevated?.enabled,
    exec_allowlist: execAllowlist,
    monitored_surfaces: [
      "workspace_filesystem",
      "outside_sibling_write_edit_apply_patch",
      "exec_allowlist_and_shell_composition",
      "configured_tool_inventory",
    ],
    outside_read_caveat: outsideReadCaveat,
    tool_receipts: receipts,
    unauthorized_effects_observed: unauthorizedEffects,
  };
  process.stdout.write(`${JSON.stringify(payload)}\n`);
} else if (mode === "author-workflow") {
  if (!receiptPath || receiptPath === "-") {
    throw new Error("native authoring receipt path is missing");
  }
  const descriptor = path.resolve(descriptorInput);
  const instructionDir = path.resolve(instructionDirInput);
  if (!inside(descriptor, workspace) || !inside(instructionDir, workspace)) {
    throw new Error("native authoring target escaped workspace");
  }
  const instructionStat = fs.lstatSync(instructionDir);
  if (!instructionStat.isDirectory() || instructionStat.isSymbolicLink()) {
    throw new Error("native authoring instruction directory is unsafe");
  }
  const receipts = [];
  for (const name of fs.readdirSync(instructionDir).sort()) {
    const target = path.join(instructionDir, name);
    const stat = fs.lstatSync(target);
    if (!stat.isFile() || stat.isSymbolicLink()) {
      throw new Error("native authoring scaffold contains a non-file entry");
    }
    const relative = path.relative(workspace, target);
    const before = fileState(target);
    await byName.apply_patch.execute(
      `hive-author-delete-${sha256(relative).slice(0, 12)}`,
      {
        input:
          "*** Begin Patch\n" +
          `*** Delete File: ${relative}\n` +
          "*** End Patch\n",
      },
    );
    const after = fileState(target);
    if (!before.exists || after.exists) {
      throw new Error("native apply_patch did not remove scaffold file");
    }
    receipts.push({
      tool: "apply_patch",
      operation: "delete scaffold file",
      path: relative,
      decision: "succeeded",
      before_sha256: before.sha256,
    });
  }
  const authored = [
    [path.join(instructionDir, "research.md"), "Research the launch.\n"],
    [path.join(instructionDir, "draft.md"), "Draft from research.md.\n"],
    [
      descriptor,
      "id: editorial\n" +
        "stages:\n" +
        "  - name: research\n" +
        "    kind: agent\n" +
        "    state_file: research.md\n" +
        "    instruction: editorial/research.md\n" +
        "    permissions: yolo\n" +
        "  - name: draft\n" +
        "    kind: agent\n" +
        "    state_file: draft.md\n" +
        "    instruction: editorial/draft.md\n" +
        "    permissions: yolo\n" +
        "  - name: approval\n" +
        "    kind: human\n" +
        "    state_file: approval.md\n" +
        "    input: draft.md\n" +
        "    outcomes:\n" +
        "      approve:\n" +
        "        complete: true\n" +
        "        artifact: draft.md\n" +
        "      reject:\n" +
        "        to: draft\n",
    ],
  ];
  for (const [target, content] of authored) {
    const relative = path.relative(workspace, target);
    await byName.write.execute(
      `hive-author-write-${sha256(relative).slice(0, 12)}`,
      { path: target, content },
    );
    const state = fileState(target);
    if (!state.exists || state.sha256 !== sha256(content)) {
      throw new Error("native write did not retain authored bytes");
    }
    receipts.push({
      tool: "write",
      operation: "author workflow file",
      path: relative,
      decision: "succeeded",
      sha256: state.sha256,
      size: state.size,
    });
  }
  const expectedNames = ["draft.md", "research.md"];
  if (
    JSON.stringify(fs.readdirSync(instructionDir).sort()) !==
    JSON.stringify(expectedNames)
  ) {
    throw new Error("native authoring left unexpected instruction entries");
  }
  const payload = {
    schema: "hive-openclaw-native-authoring",
    schema_version: 1,
    source: runtimeSource,
    proof_mode: "direct_native_tool_surface",
    model_loop: "not_exercised",
    driver_sha256: driverSha256,
    runtime_package: runtimeContract,
    public_exports: exportSpecifiers,
    workspace,
    tool_receipts: receipts,
    unauthorized_effects_observed: [],
  };
  fs.writeFileSync(receiptPath, `${JSON.stringify(payload, null, 2)}\n`, {
    encoding: "utf8",
    flag: "wx",
    mode: 0o600,
  });
  process.stdout.write(`${JSON.stringify(payload)}\n`);
} else {
  throw new Error("unknown OpenClaw native-tool driver mode");
}
