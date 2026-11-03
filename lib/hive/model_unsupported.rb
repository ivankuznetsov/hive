require "hive/agent_limit"
require "hive/secret_patterns"
require "hive/attempts/context"
require "shellwords"

module Hive
  # A provider refused the configured model outright (for example Codex on a
  # ChatGPT account answering `The 'gpt-6-sol' model is not supported when
  # using Codex with a ChatGPT account.`). This is an operator-owned
  # configuration problem, not a provider quota wall: the same request fails
  # identically on every retry until someone changes the model configured for
  # that stage/role. It is therefore classified apart from AgentLimit's
  # `limits_reached` so it never enters the hourly provider cooldown, the
  # babysitter limit hold, or the daemon healer's automatic retry.
  #
  # Supersedes PR #1473's classification, which treated this response as a
  # plan-allowance wall: in the field (Oct 2026) four review tasks retried
  # ~240 times over ~11 days because triage was configured with a model the
  # account could not use.
  module ModelUnsupported
    REASON = "model_unsupported".freeze

    PATTERNS = [
      /model is not supported when using codex with a chatgpt account/i
    ].freeze

    # Captures the model name from the provider sentence. Quotes may survive
    # JSON escaping (`\'gpt-6-sol\'`), so strip backslashes before matching.
    MODEL_RE = /\bthe\s+['"`‘’]([^'"`‘’\s]{1,128})['"`‘’]\s+model is not supported\b/i.freeze

    # Hive's own formatted error (see `error_message`). Recognized so a
    # message that has already been classified once — and then forwarded
    # through a reviewer/triage/fix result — still reads as this class.
    OWN_MESSAGE_RE = /\Amodel unsupported(?: for [a-z0-9_-]+)?:/i.freeze
    OWN_MODEL_RE = /^model unsupported(?: for [a-z0-9_-]+)?: '([^'\s]{1,128})' is not available\b/i.freeze

    CONFIG_HINT = "set a supported model for this stage/role in " \
                  ".hive-state/config.yml (models routing), then retry the task".freeze

    module_function

    def detected?(text)
      lines(text).any? do |line|
        line.match?(OWN_MESSAGE_RE) || PATTERNS.any? { |pattern| line.match?(pattern) }
      end
    end

    def marker?(attrs)
      return false unless attrs.respond_to?(:[])

      (attrs["reason"] || attrs[:reason]).to_s == REASON
    end

    def model_name(text)
      normalized = Hive::AgentLimit.normalize(text).delete("\\")
      match = normalized.match(MODEL_RE) || normalized.match(OWN_MODEL_RE)
      match && match[1]
    end

    # Full local diagnosis; markers use marker_message's compact log pointer.
    def error_message(text, agent: nil, cli_identity: nil, diagnostic_reference: nil, task: nil)
      prefix = "model unsupported"
      prefix = "#{prefix} for #{agent}" if agent && !agent.to_s.empty?
      model = model_name(text)
      subject = model ? "'#{model}' is not available to this account" : "the configured model is not available to this account"
      message = "#{prefix}: #{subject}; #{CONFIG_HINT}"
      if cli_identity
        name = agent || cli_identity.profile
        version = cli_identity.version || "unknown (#{cli_identity.version_reason || 'identity_unavailable'})"
        message += "; CLI launch_path=#{cli_identity.launch_path || 'unavailable'}" \
                   "; effective_target=#{cli_identity.effective_target || 'unknown'}" \
                   "; version=#{version}; evidence=#{cli_identity.version_source || 'unknown'}" \
                   "; regime=#{cli_identity.regime}; authority=#{cli_identity.authority}" \
                   "; a stale CLI may reject this model; verify agents.#{name}.bin and agents.#{name}.min_version"
      end
      diagnostic_reference ||= self.diagnostic_reference(text)
      if diagnostic_reference
        message += "; diagnostic=#{diagnostic_reference}; retrieve with #{log_command(text, task: task)}"
      end
      Hive::SecretPatterns.redact(message)
    end

    # Hive's own formatted line when the text already carries one (it names
    # the agent, the model and the fix); otherwise format the raw provider
    # text so every surface shows both the model and the remedy.
    def operator_message(text, agent: nil, cli_identity: nil, diagnostic_reference: nil)
      formatted = lines(text).find { |line| line.match?(OWN_MESSAGE_RE) }
      if cli_identity || diagnostic_reference
        error_message(text, agent: agent || formatted&.match(/\Amodel unsupported for ([a-z0-9_-]+):/i)&.[](1),
          cli_identity: cli_identity, diagnostic_reference: diagnostic_reference)
      else
        Hive::SecretPatterns.redact(formatted || error_message(text, agent: agent))
      end
    end

    # Only the private attempt stream and per-run log receive the full identity.
    # Worker stderr is drained into the supervisor's integrity-bearing StreamLog
    # before its terminal receipt is sealed, so this final line survives the tail.
    def record_diagnostic(text, agent:, cli_identity:, log_file: nil, task: nil)
      reference = current_reference
      message = error_message(text, agent: agent, cli_identity: cli_identity,
        diagnostic_reference: reference, task: task)
      unless cli_identity
        message += "; CLI identity/version unavailable; verify agents.#{agent}.bin and agents.#{agent}.min_version; a stale CLI may reject this model"
      end
      message = Hive::SecretPatterns.redact(message)
      warn message
      if log_file
        flags = File::WRONLY | File::APPEND | File::NOFOLLOW
        File.open(log_file, flags) { |log| log.puts(message) }
      end
      reference
    rescue SystemCallError, IOError
      reference
    end

    def current_reference
      attempt_id = Hive::Attempts::Context.current&.attempt_id
      attempt_id ? "attempt:#{attempt_id}" : "task-log"
    end

    def diagnostic_reference(text)
      text.to_s[/\bdiagnostic=(attempt:[a-zA-Z0-9_-]+|task-log)\b/, 1]
    end

    def log_command(text = nil, task: nil)
      existing = text.to_s[/\bhive task (?:[a-zA-Z0-9_-]+) --log\b/]
      return existing if existing

      id = task.id if task.respond_to?(:id)
      target = if id.to_s.match?(/\A[0-9]+\z/)
        id.to_s
      else
        task.respond_to?(:slug) ? task.slug : Hive::Attempts::Context.current&.task_slug
      end
      target = "TARGET" unless target.to_s.match?(/\A[a-zA-Z0-9_-]{1,64}\z/)
      "hive task #{Shellwords.escape(target)} --log"
    end

    # A marker is a bounded pointer to the private diagnosis, never a truncated
    # path. Keep the recognizer prefix even when provider/model names are long.
    def marker_message(text, agent: nil, diagnostic_reference: nil, task: nil)
      reference = diagnostic_reference || self.diagnostic_reference(text) || current_reference
      reference = "task-log" unless reference.match?(/\A(?:attempt:[a-zA-Z0-9_-]{1,64}|task-log)\z/)
      model = model_name(text)
      prefix = "model unsupported"
      prefix += " for #{agent}" if agent.to_s.match?(/\A[a-zA-Z0-9_-]{1,16}\z/)
      subject = model && model.bytesize <= 40 ? "'#{model}' is not available" : "configured model unavailable"
      suffix = "; choose supported model; diagnostic=#{reference}; #{log_command(text, task: task)}"
      message = "#{prefix}: #{subject}#{suffix}"
      message = "model unsupported: configured model unavailable#{suffix}" if message.bytesize > 198
      message = "model unsupported: diagnostic=#{reference}; #{log_command(text, task: task)}; set supported model" if message.bytesize > 198
      Hive::SecretPatterns.redact(message)
    end

    # Remediation shown on recovery receipts and the operational status row.
    def remediation(attrs = {})
      message = attrs.respond_to?(:[]) ? (attrs["message"] || attrs[:message]).to_s : ""
      unless message.strip.empty?
        if marker?(attrs) && !diagnostic_reference(message)
          message += "; CLI identity/version unavailable; see #{log_command(task: nil)}"
        end
        return Hive::SecretPatterns.redact(message)
      end

      "the provider rejected the configured model; #{CONFIG_HINT}"
    end

    def lines(text)
      Hive::AgentLimit.normalize(text).each_line.map(&:strip).reject(&:empty?)
    end
    private_class_method :lines
  end
end
