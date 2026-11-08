require "json"
require "json_schemer"
require "hive/cli_usage_contracts"
require "hive/errors"
require "hive/one_shot/readiness"
require "hive/schemas"

module Hive
  module OneShot
    class Result
      ROUTINE_REFUSALS = %w[daemon_owned one_shot_busy babysitter_owned].freeze

      attr_reader :exit_code

      class ReportedError < Hive::Error
        attr_reader :exit_code

        def initialize(result)
          @exit_code = result.exit_code
          super(result.to_h.dig("error", "message") || "one-shot execution failed")
        end
      end

      def self.requested?(argv)
        Array(argv).any? { |arg| arg == "--once" || arg.match?(/\A--once=(?:true|t)\z/i) }
      end

      def self.ok(component:, project:, started_at:, finished_at:, ran:, items:, safe_to_stop:, owner: nil)
        readiness = Readiness.project(items: items, finished_at: finished_at)
        new(base(component, project, started_at, finished_at).merge(
          "status" => "ok", "ran" => Array(ran), "owner" => owner_hash(owner),
          "error" => nil, "safe_to_stop" => safe_to_stop == true
        ).merge(readiness), exit_code: Hive::ExitCodes::SUCCESS)
      end

      def self.refused(component:, project:, started_at:, finished_at:, code:, message:, owner: nil)
        failed(component: component, project: project, started_at: started_at,
               finished_at: finished_at, status: "refused", code: code,
               message: message, owner: owner, ran: [])
      end

      def self.error(component:, project:, started_at:, finished_at:, code:, message:, ran: [],
                     owner: nil, exit_code: Hive::ExitCodes::TEMPFAIL, details: nil)
        failed(component: component, project: project, started_at: started_at,
               finished_at: finished_at, status: "error", code: code,
               message: message, owner: owner, ran: ran, exit_code: exit_code,
               details: details)
      end

      def self.interrupted(component:, project:, started_at:, finished_at:, message:, ran: [])
        error(
          component: component, project: project, started_at: started_at,
          finished_at: finished_at, code: "interrupted",
          message: message.to_s.empty? ? "one-shot execution interrupted" : message,
          ran: ran
        )
      end

      def self.error_payload(component:, project:, error:, now: Time.now.utc)
        code = if error.respond_to?(:code) && error.code
          error.code
        elsif error.is_a?(Hive::ConfigError)
          "config"
        else
          "usage"
        end
        self.error(
          component: component, project: project, started_at: now, finished_at: now,
          code: code, message: error.message,
          exit_code: error.respond_to?(:exit_code) ? error.exit_code : Hive::ExitCodes::USAGE
        ).to_h
      end

      def self.usage_contract(component:, project:)
        {
          error_kind: "usage",
          payload: lambda do |error, argv: []|
            error_payload(component: component, project: project, error: error)
          end
        }
      end

      def self.declare_usage_contract(name, component:, &fallback)
        Hive::CliUsageContracts.declare(name) do |argv, command_index:, option_argv:|
          if requested?(option_argv)
            project = Hive::CliUsageContracts.positionals(argv, command_index).first
            usage_contract(component: component, project: project)
          else
            fallback&.call(
              argv, command_index: command_index, option_argv: option_argv
            )
          end
        end
      end

      def self.aggregate(component:, reports:, started_at:, finished_at:)
        reports = Array(reports)
        documents = []
        rejected = []
        reports.each_with_index do |report, index|
          document = raw_document(report)
          if authoritative_document?(document)
            documents << document
          else
            identity = { "index" => index }
            identity["project"] = document["project"] if
              document.is_a?(Hash) && document["project"].is_a?(String) &&
                !document["project"].empty?
            rejected << identity
          end
        end
        valid_count = documents.size == reports.size
        routine_refusals = documents.select { |doc| routine_refusal?(doc) }
        invalid = documents.any? do |doc|
          doc["status"] != "ok" && !routine_refusal?(doc)
        end
        partial_failure = !valid_count || invalid
        successful = documents.select { |doc| doc["status"] == "ok" }
        owning = routine_refusals.map do |doc|
          { "project" => doc.fetch("project"), "owner" => doc.fetch("owner") }
        end

        if partial_failure
          document = base(component, nil, started_at, finished_at).merge(
            "status" => "error", "ran" => aggregate_ran(successful), "pending" => nil,
            "next_due_at" => nil, "wake_conditions" => [], "safe_to_stop" => false,
            "owner" => nil,
            "error" => error_hash(
              "partial_failure",
              "one or more projects did not report authoritative readiness",
              details: rejected.empty? ? nil : { "rejected_reports" => rejected }
            ),
            "projects" => documents, "owning_projects" => owning, "host_stop_allowed" => false
          )
          return new(document, exit_code: Hive::ExitCodes::TEMPFAIL)
        end

        pending = aggregate_pending(successful)
        aggregate_finished = Readiness.timestamp(finished_at)
        next_due = if pending.fetch("runnable_now").any?
          aggregate_finished
        else
          successful.filter_map { |doc| doc["next_due_at"] }.min
        end
        stop_safe = routine_refusals.empty? && successful.all? { |doc| doc["safe_to_stop"] == true }
        document = base(component, nil, started_at, finished_at).merge(
          "status" => "ok", "ran" => aggregate_ran(successful), "pending" => pending,
          "next_due_at" => next_due, "wake_conditions" => aggregate_wakes(successful),
          "safe_to_stop" => stop_safe, "owner" => nil, "error" => nil,
          "projects" => documents, "owning_projects" => owning,
          "host_stop_allowed" => stop_safe && pending.fetch("runnable_now").empty?
        )
        new(document, exit_code: Hive::ExitCodes::SUCCESS)
      end

      def initialize(document, exit_code:)
        @document = document
        @exit_code = exit_code
      end

      def to_h = @document
      def to_json(*args) = JSON.generate(@document, *args)
      def safe_to_stop? = @document["safe_to_stop"] == true

      class << self
        private

        def failed(component:, project:, started_at:, finished_at:, status:, code:, message:,
                   owner:, ran:, exit_code: Hive::ExitCodes::TEMPFAIL, details: nil)
          error = error_hash(code, message)
          error["details"] = details if details
          document = base(component, project, started_at, finished_at).merge(
            "status" => status, "ran" => Array(ran), "pending" => nil,
            "next_due_at" => nil, "wake_conditions" => [], "safe_to_stop" => false,
            "owner" => owner_hash(owner), "error" => error
          )
          if project.nil?
            document.merge!(
              "projects" => [], "owning_projects" => [], "host_stop_allowed" => false
            )
          end
          new(document, exit_code: exit_code)
        end

        def base(component, project, started_at, finished_at)
          {
            "schema" => "hive-one-shot", "schema_version" => 1,
            "component" => component.to_s, "project" => project,
            "started_at" => Readiness.timestamp(started_at),
            "finished_at" => Readiness.timestamp(finished_at)
          }
        end

        def error_hash(code, message, details: nil)
          { "code" => code.to_s, "message" => message.to_s }.tap do |error|
            error["details"] = details if details
          end
        end

        def owner_hash(owner)
          return nil unless owner.is_a?(Hash)

          owner.slice("kind", "pid", "process_identity", "state_root", "started_at")
        end

        def raw_document(report) = report.respond_to?(:to_h) ? report.to_h : report

        def authoritative_document?(document)
          document.is_a?(Hash) &&
            document["project"].is_a?(String) && !document["project"].empty? &&
            one_shot_schemer.valid?(document)
        end

        def one_shot_schemer
          @one_shot_schemer ||= JSONSchemer.schema(
            JSON.parse(File.read(Hive::Schemas.schema_path("hive-one-shot")))
          )
        end

        def routine_refusal?(document)
          document["status"] == "refused" &&
            ROUTINE_REFUSALS.include?(document.dig("error", "code")) &&
            document["owner"].is_a?(Hash)
        end

        def aggregate_pending(documents)
          Readiness::BUCKETS.to_h do |bucket|
            rows = documents.flat_map do |document|
              Array(document.dig("pending", bucket)).map do |item|
                prefix_item(document.fetch("project"), item)
              end
            end
            [ bucket, rows ]
          end
        end

        def aggregate_ran(documents)
          documents.flat_map do |document|
            Array(document["ran"]).map { |item| prefix_item(document.fetch("project"), item) }
          end
        end

        def prefix_item(project, item)
          item.merge("id" => "#{project}:#{item.fetch("id")}", "project" => project)
        end

        def aggregate_wakes(documents)
          items = documents.flat_map do |document|
            Array(document["wake_conditions"]).flat_map do |wake|
              condition = wake.reject { |key, _value| key == "affected_pending_ids" }
              Array(wake["affected_pending_ids"]).map do |id|
                {
                  "id" => "#{document.fetch("project")}:#{id}",
                  "condition" => condition
                }
              end
            end
          end
          Readiness.group_by_condition(items)
        end
      end
    end
  end
end
