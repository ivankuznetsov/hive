import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const text = (value) => ({ content: [{ type: "text", text: value }] });

const confined = (workspace, input) => {
  const target = path.resolve(workspace, input);
  const relative = path.relative(workspace, target);
  if (
    relative === "" ||
    relative === ".." ||
    relative.startsWith(`..${path.sep}`) ||
    path.isAbsolute(relative)
  ) {
    throw new Error("workspace-only denial");
  }
  return target;
};

const parsePatch = (workspace, input) => {
  const deleteMatch = input.match(/\*\*\* Delete File: (.+)\n/);
  if (deleteMatch) {
    return { operation: "delete", target: confined(workspace, deleteMatch[1]) };
  }
  const updateMatch = input.match(/\*\*\* Update File: (.+)\n/);
  if (!updateMatch) throw new Error("unsupported fixture patch");
  const body = input.split("@@\n", 2)[1]?.split("*** End Patch", 1)[0] ?? "";
  const removed = body
    .split("\n")
    .filter((line) => line.startsWith("-"))
    .map((line) => line.slice(1))
    .join("\n");
  const added = body
    .split("\n")
    .filter((line) => line.startsWith("+"))
    .map((line) => line.slice(1))
    .join("\n");
  return {
    operation: "update",
    target: confined(workspace, updateMatch[1]),
    removed,
    added,
  };
};

export function createOpenClawCodingTools(options) {
  const workspace = path.resolve(options.workspaceDir);
  const config = options.config;
  const tools = [
    {
      name: "read",
      async execute(_id, input) {
        return text(fs.readFileSync(confined(workspace, input.path), "utf8"));
      },
    },
    {
      name: "write",
      async execute(_id, input) {
        const target = confined(workspace, input.path);
        fs.writeFileSync(target, input.content);
        return text("written");
      },
    },
    {
      name: "edit",
      async execute(_id, input) {
        const target = confined(workspace, input.path);
        let content = fs.readFileSync(target, "utf8");
        for (const edit of input.edits) {
          if (!content.includes(edit.oldText)) throw new Error("edit text missing");
          content = content.replace(edit.oldText, edit.newText);
        }
        fs.writeFileSync(target, content);
        return text("edited");
      },
    },
    {
      name: "apply_patch",
      async execute(_id, input) {
        const patch = parsePatch(workspace, input.input);
        if (patch.operation === "delete") {
          fs.unlinkSync(patch.target);
        } else {
          const content = fs.readFileSync(patch.target, "utf8");
          if (!content.includes(patch.removed)) {
            throw new Error("patch text missing");
          }
          fs.writeFileSync(
            patch.target,
            content.replace(patch.removed, patch.added),
          );
        }
        return text("patched");
      },
    },
    {
      name: "exec",
      async execute(_id, input) {
        if (input.command !== "hive version") {
          throw new Error("exec denied: allowlist miss");
        }
        const gateway = path.join(config.tools.exec.pathPrepend[0], "hive");
        const result = spawnSync(gateway, ["version"], {
          cwd: input.workdir || workspace,
          encoding: "utf8",
        });
        if (result.status !== 0) {
          throw new Error(result.stderr || "gateway command failed");
        }
        return text(result.stdout);
      },
    },
    {
      name: "process",
      async execute() {
        throw new Error("process should be removed by policy");
      },
    },
  ];
  return tools.filter((tool) => config.tools.allow.includes(tool.name));
}
