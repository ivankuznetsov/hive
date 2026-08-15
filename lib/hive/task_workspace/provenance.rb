require "json"
require "pathname"
require "hive/context_provenance"
require "hive/task_workspace"

module Hive
  module TaskWorkspace
    # Projects immutable attempt-bound launch/selection receipts beside a
    # separately observed repository/Wiki snapshot. Missing legacy receipts
    # remain missing; current state is never copied into historical fields.
    class Provenance
      RECEIPT_BYTES = Hive::ContextProvenance::MAX_RECEIPT_BYTES

      def initialize(task:, attempts_panel:, limits: Limits.new, reader: nil,
                     current_observation: nil, clock: -> { Time.now.utc })
        @task = task
        @attempts_panel = attempts_panel
        @limits = limits
        @reader = reader || BoundedReader.new(root: task.folder)
        @current_observation = current_observation
        @clock = clock
      end

      def call
        diagnostics = []
        budget = BoundedReader::Budget.new(@limits.fetch(:projection_snapshot_bytes))
        current = normalize_current(observe_current, diagnostics)
        records = Array(@attempts_panel["records"]).map do |attempt|
          project_attempt(attempt, current, budget, diagnostics)
        end

        states = records.map { |record| record.fetch("state") }
        state = if states.include?("conflicting")
          "conflicting"
        elsif states.include?("stale")
          "stale"
        elsif records.empty? || states.any? { |value| %w[partial missing unavailable].include?(value) } ||
              current["state"] != "current" || diagnostics.any?
          records.empty? && current["state"] == "unavailable" ? "unavailable" : "partial"
        else
          "current"
        end
        if records.empty?
          diagnostics << diagnostic("historical_receipts_missing", source: "controller_receipt")
        end

        {
          "state" => state,
          "records" => records,
          "current_observation" => current,
          "diagnostics" => diagnostics.uniq,
          "truncated" => diagnostics.any? { |row| row.dig("details", "cap") },
          "observed_bytes" => budget.consumed
        }
      rescue StandardError => e
        {
          "state" => "unavailable", "records" => [],
          "current_observation" => unavailable_current,
          "diagnostics" => [ diagnostic("projection_failed", e.class.name) ],
          "truncated" => false, "observed_bytes" => 0
        }
      end

      private

      def observe_current
        @current_observation || Hive::ContextProvenance.observe_current(
          task: @task, clock: @clock
        )
      rescue StandardError
        nil
      end

      def normalize_current(value, diagnostics)
        input = value.to_h.transform_keys(&:to_s)
        repository = safe_context(input["repository"])
        wiki = safe_context(input["wiki"])
        state = context_state(repository, wiki)
        {
          "state" => state,
          "observed_at" => valid_time(input["observed_at"]),
          "repository" => field(
            repository, state: value_state(repository), source: "current_observation",
            quality: "observed_current"
          ),
          "wiki" => field(
            wiki, state: value_state(wiki), source: "current_observation",
            quality: "observed_current"
          )
        }
      rescue StandardError => e
        diagnostics << diagnostic("current_observation_invalid", e.class.name)
        unavailable_current
      end

      def project_attempt(attempt, current, budget, diagnostics)
        id = safe_attempt_id(attempt["attempt_id"])
        launch_ref = "context-receipts/#{id}.launch.json"
        agent_ref = "context-receipts/#{id}.json"
        launch = read_receipt(
          launch_ref, expected_kind: "controller_launch", expected_quality: "observed_at_launch",
          attempt: attempt, source: "controller_receipt", budget: budget, diagnostics: diagnostics
        )
        agent = read_receipt(
          agent_ref, expected_kind: "agent_selection", expected_quality: "agent_asserted_used",
          attempt: attempt, source: "agent_receipt", budget: budget, diagnostics: diagnostics
        )

        repository = historical_field(launch, agent, "repository")
        wiki = historical_field(launch, agent, "wiki")
        selection = receipt_field(agent, "selection", source: "agent_receipt")
        repository_consistency = compare_repository(repository, current.fetch("repository"))
        wiki_consistency = compare_wiki(wiki, current.fetch("wiki"))
        state = attempt_state(
          launch: launch, agent: agent, repository: repository,
          repository_consistency: repository_consistency,
          wiki_consistency: wiki_consistency
        )
        {
          "attempt_id" => id,
          "stage" => attempt["stage"],
          "task_generation" => attempt["task_generation"],
          "current" => attempt["current"] == true,
          "state" => state,
          "repository" => repository,
          "wiki" => wiki,
          "selection" => selection,
          "consistency" => {
            "repository" => repository_consistency,
            "wiki" => wiki_consistency
          },
          "receipts" => {
            "controller" => receipt_summary(launch),
            "agent" => receipt_summary(agent)
          }
        }
      rescue ArgumentError => e
        diagnostics << diagnostic("attempt_binding_invalid", e.class.name)
        {
          "attempt_id" => "unavailable", "stage" => attempt["stage"],
          "task_generation" => attempt["task_generation"],
          "current" => attempt["current"] == true, "state" => "unavailable",
          "repository" => missing_field("controller_receipt"),
          "wiki" => missing_field("controller_receipt"),
          "selection" => missing_field("agent_receipt"),
          "consistency" => { "repository" => "unavailable", "wiki" => "unavailable" },
          "receipts" => {}
        }
      end

      def read_receipt(reference, expected_kind:, expected_quality:, attempt:, source:,
                       budget:, diagnostics:)
        result = @reader.read(reference, max_bytes: RECEIPT_BYTES, budget: budget)
        if result.truncated
          diagnostics << diagnostic(
            "receipt_limit_exhausted", nil, source: source,
            "cap" => "context_receipt_bytes", "limit" => RECEIPT_BYTES,
            "observed" => result.bytes, "reference" => reference
          )
          return missing_receipt(source, reference, state: "partial")
        end
        if result.binary || result.invalid_encoding
          diagnostics << diagnostic("receipt_encoding_invalid", nil, source: source,
                                    "reference" => reference)
          return missing_receipt(source, reference, state: "unavailable")
        end

        receipt = JSON.parse(result.content)
        validate_receipt!(
          receipt, expected_kind: expected_kind, expected_quality: expected_quality,
          attempt: attempt
        )
        {
          "state" => receipt_state(receipt), "source" => source,
          "evidence_ref" => reference, "receipt" => receipt
        }
      rescue SourceError => e
        return missing_receipt(source, reference) if e.reason == "missing"

        diagnostics << e.diagnostic.merge("source" => source, "reference" => reference)
        missing_receipt(source, reference, state: "unavailable")
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError => e
        diagnostics << diagnostic("receipt_invalid", e.class.name, source: source,
                                  "reference" => reference)
        missing_receipt(source, reference, state: "unavailable")
      end

      def validate_receipt!(receipt, expected_kind:, expected_quality:, attempt:)
        raise ArgumentError, "receipt must be an object" unless receipt.is_a?(Hash)
        allowed = %w[
          schema schema_version kind binding captured_at quality repository wiki selection diagnostics
        ]
        raise ArgumentError, "receipt keys are invalid" unless receipt.keys.sort == allowed.sort
        unless receipt["schema"] == "hive-context-receipt" && receipt["schema_version"] == 1 &&
               receipt["kind"] == expected_kind && receipt["quality"] == expected_quality
          raise ArgumentError, "receipt envelope is invalid"
        end
        Time.iso8601(receipt.fetch("captured_at").to_s)
        binding = receipt.fetch("binding")
        raise ArgumentError, "receipt binding is invalid" unless binding.is_a?(Hash)
        expected = {
          "task_slug" => @task.slug.to_s,
          "task_id" => task_id_string,
          "stage" => attempt["stage"].to_s,
          "attempt_id" => attempt["attempt_id"].to_s,
          "task_generation" => attempt["task_generation"]
        }
        expected.each do |key, value|
          raise ArgumentError, "receipt binding mismatch" unless binding[key] == value
        end
        project = attempt["project_slug"].to_s
        if !project.empty? && binding["project"].to_s != project
          raise ArgumentError, "receipt project binding mismatch"
        end
        validate_selection!(receipt["selection"]) if expected_kind == "agent_selection"
        TaskWorkspace.safe_value!(receipt)
      end

      def validate_selection!(selection)
        raise ArgumentError, "selection is invalid" unless selection.is_a?(Hash)
        Array(selection["references"]).each do |entry|
          reference = entry.is_a?(Hash) ? entry["path"].to_s.tr("\\", "/") : ""
          path = Pathname.new(reference)
          if reference.empty? || path.absolute? || path.each_filename.any? { |part| part == ".." }
            raise ArgumentError, "selection reference is unsafe"
          end
        end
      end

      def historical_field(launch, agent, key)
        candidates = [ launch, agent ].filter_map do |receipt|
          value = receipt.dig("receipt", key)
          next if value.nil?

          {
            "value" => safe_context(value),
            "state" => value_state(value),
            "source" => receipt.fetch("source"),
            "evidence_ref" => receipt.fetch("evidence_ref"),
            "observed_at" => receipt.dig("receipt", "captured_at"),
            "quality" => receipt.dig("receipt", "quality"),
            "truncated" => receipt["state"] == "partial"
          }
        end
        return missing_field("controller_receipt") if candidates.empty?

        Field.resolve(candidates).to_h
      end

      def receipt_field(receipt, key, source:)
        value = receipt.dig("receipt", key)
        field(
          value, state: value.nil? ? receipt.fetch("state") : "current",
          source: source, evidence_ref: receipt["evidence_ref"],
          observed_at: receipt.dig("receipt", "captured_at"),
          quality: receipt.dig("receipt", "quality")
        )
      end

      def compare_repository(historical, current)
        return "conflicting" if historical["state"] == "conflicting"
        left = historical["value"]
        right = current["value"]
        return "partial" unless left.is_a?(Hash) && right.is_a?(Hash)

        left_identity = [ left["repository"], left["head_oid"] ]
        right_identity = [ right["repository"], right["head_oid"] ]
        return "partial" if left_identity.any?(&:nil?) || right_identity.any?(&:nil?)

        left_identity == right_identity ? "current" : "stale"
      end

      def compare_wiki(historical, current)
        return "conflicting" if historical["state"] == "conflicting"
        left = historical["value"]
        right = current["value"]
        return "partial" unless left.is_a?(Hash) && right.is_a?(Hash)
        return "partial" if left["identity_kind"].to_s.empty? ||
                            left["identity_kind"] != right["identity_kind"]
        return "partial" if left["identifier"].nil? || right["identifier"].nil?

        left["identifier"] == right["identifier"] ? "current" : "stale"
      end

      def attempt_state(launch:, agent:, repository:, repository_consistency:, wiki_consistency:)
        return "conflicting" if repository["state"] == "conflicting" ||
                                [ repository_consistency, wiki_consistency ].include?("conflicting")
        return "stale" if [ repository_consistency, wiki_consistency ].include?("stale")
        return "partial" unless launch["state"] == "current" && agent["state"] == "current"
        return "partial" if [ repository_consistency, wiki_consistency ].include?("partial")

        "current"
      end

      def receipt_state(receipt)
        embedded = [ receipt.dig("repository", "state"), receipt.dig("wiki", "state") ].compact
        embedded.all? { |state| state == "current" } ? "current" : "partial"
      end

      def receipt_summary(receipt)
        {
          "state" => receipt.fetch("state"), "source" => receipt.fetch("source"),
          "evidence_ref" => receipt.fetch("evidence_ref"),
          "captured_at" => receipt.dig("receipt", "captured_at"),
          "quality" => receipt.dig("receipt", "quality")
        }
      end

      def context_state(repository, wiki)
        states = [ repository, wiki ].filter_map do |value|
          value["state"] if value.is_a?(Hash)
        end
        return "unavailable" if states.empty?
        return "current" if states.all? { |state| state == "current" }

        "partial"
      end

      def safe_context(value)
        return nil if value.nil?

        copy = JSON.parse(JSON.generate(value))
        TaskWorkspace.safe_value!(copy)
      end

      def value_state(value)
        return "missing" if value.nil?
        return value["state"] if value.is_a?(Hash) && STATES.include?(value["state"].to_s)

        "current"
      end

      def field(value, state:, source:, evidence_ref: nil, observed_at: nil, quality: nil)
        Field.new(
          value: value, state: state, source: source, evidence_ref: evidence_ref,
          observed_at: observed_at, quality: quality
        ).to_h
      end

      def missing_field(source)
        field(nil, state: "missing", source: source)
      end

      def missing_receipt(source, reference, state: "missing")
        {
          "state" => state, "source" => source,
          "evidence_ref" => reference, "receipt" => nil
        }
      end

      def unavailable_current
        {
          "state" => "unavailable", "observed_at" => nil,
          "repository" => field(nil, state: "unavailable", source: "current_observation"),
          "wiki" => field(nil, state: "unavailable", source: "current_observation")
        }
      end

      def task_id_string
        value = @task.respond_to?(:id) ? @task.id : nil
        value&.to_s
      end

      def safe_attempt_id(value)
        id = value.to_s
        unless id.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/)
          raise ArgumentError, "attempt id is invalid"
        end
        id
      end

      def valid_time(value)
        return nil if value.nil?

        Time.iso8601(value.to_s).utc.iso8601(6)
      rescue ArgumentError
        nil
      end

      def diagnostic(reason, message = nil, source: "current_observation", **details)
        {
          "source" => source, "reason" => reason,
          "message" => Hive::SecretPatterns.redact(message.to_s),
          "details" => details
        }
      end
    end
  end
end
