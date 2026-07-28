export const OpenClawSchema = {
  parse(value) {
    const tools = value?.tools;
    if (
      !Array.isArray(tools?.allow) ||
      tools?.fs?.workspaceOnly !== true ||
      tools?.elevated?.enabled !== false ||
      tools?.exec?.applyPatch?.enabled !== true ||
      tools?.exec?.applyPatch?.workspaceOnly !== true
    ) {
      throw new Error("fixture received an invalid OpenClaw config");
    }
    return value;
  },
};
