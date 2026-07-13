import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// GLM buffers tool arguments unless its provider-specific tool streaming flag
// is enabled. A large write call can therefore leave OpenRouter with no SSE
// traffic long enough for the upstream idle timeout to terminate the response.
// This changes only transport framing; the model, prompt, tools, and arguments
// remain the benchmark candidate's own.
export default function enableGlmToolStreaming(pi: ExtensionAPI) {
  pi.on("before_provider_request", (event) => {
    if (event.payload?.model !== "z-ai/glm-5.2") return;

    return { ...event.payload, tool_stream: true };
  });
}
