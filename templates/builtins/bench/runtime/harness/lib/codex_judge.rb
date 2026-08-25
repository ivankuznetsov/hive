# frozen_string_literal: true

require "open3"
require "json"
require "pathname"
require "tmpdir"
require "fileutils"
require "lib/judge_output"
require "lib/agent_limit"

module HiveBench
  # Judge_fn backed by the codex CLI (exec mode). By default it rides the
  # operator's ChatGPT subscription; an explicit OpenRouter route is available
  # for the same pinned model when the subscription provider is unavailable.
  #
  # The prompt arrives on stdin (`codex exec -`): judge prompts carry a full
  # diff + reference and overflow argv limits. `--skip-git-repo-check` because
  # the judge runs from wherever the harness sits, not a trusted repo;
  # `--dangerously-bypass-approvals-and-sandbox` is NOT passed — the judge
  # only reads the prompt and writes text.
  #
  # The default bin is an explicit path: /usr/bin/codex (0.140, the system
  # package) predates gpt-5.6-sol and shadows the npm 0.144 install on PATH.
  module CodexJudge
    Error = JudgeOutput::Error

    DEFAULT_TIMEOUT = 1800 # sol at xhigh reasons long on big diffs
    DEFAULT_BIN = File.expand_path("~/.local/share/mise/installs/node/26.2.0/bin/codex")
    DEFAULT_MODEL = "gpt-5.6-sol"
    DEFAULT_EFFORT = "xhigh"
    DEFAULT_PROVIDER = "chatgpt"
    OPENROUTER_PROVIDER = "openrouter"
    PROVIDERS = [ DEFAULT_PROVIDER, OPENROUTER_PROVIDER ].freeze
    PROVIDER_ROUTE_VERSION = 1

    module_function

    # Returns a judge_fn: ->(prompt:, seed:) => { score:, reason: }.
    def judge_fn(bin: DEFAULT_BIN, model: DEFAULT_MODEL, effort: DEFAULT_EFFORT,
                 timeout_s: DEFAULT_TIMEOUT, provider: DEFAULT_PROVIDER, provider_model: nil)
      provider = provider.to_s
      unless PROVIDERS.include?(provider)
        raise ArgumentError, "unknown codex judge provider #{provider.inspect}; expected #{PROVIDERS.join(" or ")}"
      end
      if provider == OPENROUTER_PROVIDER && provider_model.to_s.strip.empty?
        raise ArgumentError, "provider_model is required for the OpenRouter codex judge route"
      end

      lambda do |prompt:, seed:|
        _ = seed
        if provider == OPENROUTER_PROVIDER && ENV["OPENROUTER_API_KEY"].to_s.strip.empty?
          raise Error, "OPENROUTER_API_KEY is required for the OpenRouter codex judge route"
        end

        argv = [ "timeout", timeout_s.to_s, bin, "exec", "--skip-git-repo-check" ]
        argv += [ "--ephemeral", "--ignore-user-config", "--ignore-rules" ]
        argv += [ "-m", provider == OPENROUTER_PROVIDER ? provider_model : model ] if model
        if provider == OPENROUTER_PROVIDER
          argv += [
            "--config", 'model_provider="openrouter"',
            "--config", 'model_providers.openrouter.name="OpenRouter"',
            "--config", 'model_providers.openrouter.base_url="https://openrouter.ai/api/v1"',
            "--config", 'model_providers.openrouter.env_key="OPENROUTER_API_KEY"',
            "--config", 'model_providers.openrouter.wire_api="responses"',
            "--config", "model_providers.openrouter.requires_openai_auth=false"
          ]
        end
        argv += [ "--config", "model_reasoning_effort=#{effort}" ] if effort
        argv << "-"
        # The pinned npm Codex entrypoint uses `#!/usr/bin/env node`. Hive's
        # deliberately narrow agent PATH can contain mise's node shim without
        # the matching active tool version, even though the pinned executable
        # and node binary live beside each other. Scope the executable's own
        # directory to this child only so it resolves its sibling runtime
        # without mutating the operator's global mise configuration.
        child_env = if Pathname.new(bin).absolute?
          { "PATH" => [ File.dirname(bin), ENV["PATH"] ].compact.join(File::PATH_SEPARATOR) }
        else
          {}
        end
        # Every Codex judge runs from an empty temporary workspace so project
        # AGENTS.md instructions cannot turn scoring into implementation work.
        # OpenRouter supplies auth directly by environment and additionally gets
        # a private Codex home. ChatGPT retains the operator home for subscription
        # auth, while the CLI flags above still exclude its config, rules, and
        # persisted sessions from the one-shot judge.
        out, err, status = Dir.mktmpdir("hive-bench-codex-judge") do |root|
          workspace = File.join(root, "workspace")
          FileUtils.mkdir_p(workspace)
          isolated_env = child_env
          if provider == OPENROUTER_PROVIDER
            codex_home = File.join(root, "codex-home")
            FileUtils.mkdir_p(codex_home)
            isolated_env = child_env.merge("CODEX_HOME" => codex_home)
          end
          Open3.capture3(
            isolated_env,
            *argv,
            stdin_data: prompt.to_s,
            chdir: workspace
          )
        end
        raise Error, "codex judge timed out after #{timeout_s}s" if status.exitstatus == 124

        unless status.success?
          # Codex prints a long CLI banner (and sometimes the prompt) before the
          # provider error. Classify the complete stream before truncating it so
          # rejudge's short warning still carries a machine-readable limit marker.
          error_class = AgentLimit.limit_hit?(err) ? ProviderLimitError : Error
          raise error_class, "codex judge exited #{status.exitstatus}: #{err.strip[0, 300]}"
        end

        JudgeOutput.parse_score(out)
      end
    end
  end
end
