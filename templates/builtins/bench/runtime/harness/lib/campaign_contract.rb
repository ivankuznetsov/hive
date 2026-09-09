# frozen_string_literal: true

require_relative "codex_judge"
require "json"
require "open3"

module HiveBench
  # Shared validation and argument compilation for the campaign fields consumed
  # by both generate.md and judge.md. Keeping this here makes a campaign route
  # mean the same thing before generation spend and during judge backfill.
  module CampaignContract
    VERSION = 1
    JUDGE_BACKENDS = %w[claude codex openrouter].freeze

    module_function

    def validate_generation!(data, repo_root:)
      abort("campaign.yml must be a YAML mapping") unless data.is_a?(Hash)
      required = %w[
        campaign_id source corpus_version tasks candidates effort_pins seeds judges
        budgets timeouts exclusions aggregation
      ]
      missing = required.reject { |key| data.key?(key) }
      abort("campaign.yml missing required key(s): #{missing.join(", ")}") unless missing.empty?

      validate_common!(data)
      validate_marker_runtime!(source(data, repo_root: repo_root))
      corpus_version = data["corpus_version"]
      unless (corpus_version.is_a?(String) || corpus_version.is_a?(Integer)) &&
             !corpus_version.to_s.include?("\n")
        abort("corpus_version must be a single-line scalar; got #{corpus_version.inspect}")
      end
      %w[tasks candidates].each do |key|
        abort("#{key} must be a non-empty array") unless data[key].is_a?(Array) && !data[key].empty?
      end
      if data.key?("require_successful_execution") &&
         ![ true, false ].include?(data["require_successful_execution"])
        abort("require_successful_execution must be true or false")
      end
      validate_isolation!(data.fetch("isolation", {}))
      validate_matrix!(data)

      timeouts = data["timeouts"]
      abort("timeouts must be a mapping") unless timeouts.is_a?(Hash)
      hive_timeout = timeouts["hive_seconds"]
      unless hive_timeout.nil? || (hive_timeout.is_a?(Integer) && hive_timeout.positive?)
        abort("timeouts.hive_seconds must be a positive integer when set")
      end

      load_candidates
      known = HiveBench::Candidates.all.map(&:id)
      unknown = data["candidates"].map(&:to_s) - known
      abort("unknown candidate id(s): #{unknown.join(", ")}") unless unknown.empty?
      unknown_tasks = data["tasks"].map(&:to_s).reject do |slug|
        File.file?(File.join(repo_root, "corpus", slug, "manifest.yml"))
      end
      abort("unknown corpus task(s): #{unknown_tasks.join(", ")}") unless unknown_tasks.empty?
      data
    end

    def validate_judging!(data)
      abort("campaign.yml must be a YAML mapping") unless data.is_a?(Hash)
      required = %w[campaign_id source seeds judges]
      missing = required.reject { |key| data.key?(key) }
      abort("campaign.yml missing required key(s): #{missing.join(", ")}") unless missing.empty?

      validate_common!(data)
      data
    end

    def validate_common!(data)
      id = data["campaign_id"].to_s
      unless id.match?(/\A[a-z0-9][a-z0-9-]{0,63}\z/)
        abort("campaign_id must be a slug matching /\\A[a-z0-9][a-z0-9-]{0,63}\\z/; got #{id.inspect}")
      end
      abort("campaign_id v3-example is the unedited example id; pick a real campaign id") if id == "v3-example"

      abort("seeds must be a positive integer") unless data["seeds"].is_a?(Integer) && data["seeds"].positive?
      enabled_judges(data["judges"])
    end

    def source(data, repo_root:)
      value = data.fetch("source")
      unless value.is_a?(String) && !value.include?("\n") && !value.strip.empty?
        abort("source must be a non-empty single-line string; got #{value.inspect}")
      end

      File.expand_path(value, repo_root)
    end

    def validate_marker_runtime!(source)
      missing = %w[hive/agent_limit.rb hive/markers.rb].reject do |relative|
        File.file?(File.join(source, "lib", relative))
      end
      return if missing.empty?

      abort("source does not contain the campaign marker runtime: #{missing.join(", ")}")
    end

    def enabled_judges(judges)
      abort("judges must be a mapping") unless judges.is_a?(Hash)

      unknown = judges.keys.map(&:to_s) - JUDGE_BACKENDS
      abort("unknown judge backend(s): #{unknown.join(", ")}") unless unknown.empty?

      enabled = judges.reject { |_backend, config| config.nil? || config == false }
      abort("at least two judge backends must be enabled") if enabled.size < 2
      enabled.each do |backend, config|
        abort("judges.#{backend} must be a mapping or null") unless config.is_a?(Hash)

        model = config["model"]
        unless model.is_a?(String) && !model.include?("\n") && !model.strip.empty?
          abort("judges.#{backend}.model must be a non-empty single-line string")
        end
      end

      names = enabled.map { |backend, config| judge_name(backend, config) }
      unless names.uniq.size == names.size
        abort("enabled judges must produce unique result keys; got #{names.inspect}")
      end

      validate_codex!(enabled["codex"]) if enabled.key?("codex")
      enabled
    end

    def judge_arguments(judges, openrouter_model_flag:)
      enabled = enabled_judges(judges)
      args = []
      if (claude = enabled["claude"])
        args += [ "--claude-judge", "--judge-model", claude.fetch("model").to_s ]
      else
        args << "--no-claude-judge"
      end
      if (codex = enabled["codex"])
        provider = codex.fetch("provider", CodexJudge::DEFAULT_PROVIDER).to_s
        args += [
          "--codex-judge", "--codex-judge-model", codex.fetch("model").to_s,
          "--codex-judge-effort", codex.fetch("reasoning_effort").to_s,
          "--codex-judge-provider", provider
        ]
        if provider == CodexJudge::OPENROUTER_PROVIDER
          args += [ "--codex-judge-provider-model", codex.fetch("provider_model").to_s ]
        end
      else
        args << "--no-codex-judge"
      end
      if (openrouter = enabled["openrouter"])
        args += [ "--openrouter-judge", openrouter_model_flag, openrouter.fetch("model").to_s ]
      else
        args << "--no-openrouter-judge"
      end
      args
    end

    def judges_require_openrouter?(judges)
      enabled = enabled_judges(judges)
      enabled.key?("openrouter") ||
        enabled.dig("codex", "provider") == CodexJudge::OPENROUTER_PROVIDER
    end

    def campaign_requires_openrouter?(data)
      return true if judges_require_openrouter?(data.fetch("judges"))

      load_candidates
      data.fetch("candidates").any? do |id|
        candidate = HiveBench::Candidates.by_id(id.to_s)
        candidate && (candidate.pi_models || candidate.opencode_models)
      end
    end

    def judge_name(backend, config)
      model = config.fetch("model")
      backend.to_s == "claude" ? model.sub(/\Aclaude-/, "") : model.split("/").last
    end

    def verify_generation_network!(data, inspector: nil)
      isolation = data.fetch("isolation", {})
      return unless isolation["require_provider_egress"] == true

      network = isolation.fetch("docker_network")
      proxy = isolation.fetch("https_proxy")
      proxy_host = proxy.match(
        %r{\Ahttp://(?<host>[a-zA-Z0-9][a-zA-Z0-9.-]{0,126}):[1-9]\d{0,4}\z}
      )&.[](:host)
      abort("isolation.https_proxy must be a credential-free internal http://host:port URL") unless proxy_host

      metadata = (inspector || method(:inspect_generation_network)).call(network)
      abort("isolation.docker_network must be an internal Docker network") unless metadata["Internal"] == true

      peers = metadata.fetch("Containers", {}).values.filter_map do |peer|
        peer["Name"] if peer.is_a?(Hash)
      end
      return if peers == [ proxy_host ]

      abort("isolation.docker_network must contain only proxy #{proxy_host}; found #{peers.sort.inspect}")
    end

    def validate_codex!(config)
      effort = config["reasoning_effort"]
      unless effort.is_a?(String) && !effort.include?("\n") && !effort.strip.empty?
        abort("judges.codex.reasoning_effort must be a non-empty single-line string")
      end

      provider = config.fetch("provider", CodexJudge::DEFAULT_PROVIDER).to_s
      unless CodexJudge::PROVIDERS.include?(provider)
        abort("judges.codex.provider must be #{CodexJudge::PROVIDERS.join(' or ')}")
      end
      return unless provider == CodexJudge::OPENROUTER_PROVIDER

      provider_model = config["provider_model"]
      return if provider_model.is_a?(String) && !provider_model.include?("\n") && !provider_model.strip.empty?

      abort("judges.codex.provider_model must be a non-empty single-line string for provider openrouter")
    end

    def validate_isolation!(isolation)
      abort("isolation must be a mapping") unless isolation.is_a?(Hash)
      if isolation.key?("sealed_agent_runtime") &&
         ![ true, false ].include?(isolation["sealed_agent_runtime"])
        abort("isolation.sealed_agent_runtime must be true or false")
      end
      if isolation["require_provider_egress"] == true
        network = isolation["docker_network"]
        proxy = isolation["https_proxy"]
        unless network.is_a?(String) && network.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/)
          abort("isolation.docker_network must be a safe Docker network name")
        end
        unless proxy.is_a?(String) &&
               proxy.match?(%r{\Ahttp://[a-zA-Z0-9][a-zA-Z0-9.-]{0,126}:[1-9]\d{0,4}\z})
          abort("isolation.https_proxy must be a credential-free internal http://host:port URL")
        end
      elsif isolation.key?("require_provider_egress") && isolation["require_provider_egress"] != false
        abort("isolation.require_provider_egress must be true or false")
      end
    end

    def validate_matrix!(data)
      exclusions = data["exclusions"]
      abort("exclusions must be an array") unless exclusions.is_a?(Array)
      bad = exclusions.reject do |item|
        item.is_a?(Hash) && item.key?("task") && item.key?("candidate")
      end
      abort("every exclusions entry must be a {task:, candidate:} map; bad: #{bad.inspect}") unless bad.empty?

      excluded = exclusions.map { |item| [ item["task"].to_s, item["candidate"].to_s ] }
      matrix = data["tasks"].flat_map do |task|
        data["candidates"].map { |candidate| [ task.to_s, candidate.to_s ] }
      end - excluded
      abort("campaign matrix is empty: every tasks x candidates cell is excluded") if matrix.empty?
    end

    def inspect_generation_network(network)
      out, err, status = Open3.capture3("docker", "network", "inspect", network)
      abort("cannot inspect benchmark generation network #{network}: #{err.strip}") unless status.success?

      metadata = JSON.parse(out)
      value = metadata.is_a?(Array) ? metadata.first : nil
      abort("cannot inspect benchmark generation network #{network}: invalid output") unless value.is_a?(Hash)

      value
    rescue JSON::ParserError => e
      abort("cannot inspect benchmark generation network #{network}: #{e.message}")
    end

    def load_candidates
      require_relative "../profiles/candidates"
    end
    private_class_method :validate_common!, :validate_codex!, :validate_isolation!,
                         :validate_matrix!, :inspect_generation_network, :load_candidates
  end
end
