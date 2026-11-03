require "json"
require "hive/task_capabilities/revision"
require "hive/task_resolver"
require "hive/schemas"
require "hive/command_error_kind"

module Hive
  module Commands
    class TaskCapabilities
      include Hive::Schemas::EnvelopeEmitter
      ACTIONS = %w[propose show accept reject waive risk-accept].freeze

      def initialize(action, target, project: nil, json: false, resolver: nil, **options)
        @action, @target, @project, @json, @options = action, target, project, json, options
        @resolver = resolver || -> { Hive::TaskResolver.new(@target, project_filter: @project).resolve }
      end

      def call
        call_with_envelope do
          raise Hive::UsageError, "expected task-capabilities #{ACTIONS.join('/')} TARGET" unless ACTIONS.include?(@action) && !@target.to_s.empty?
          Hive::TaskCapabilities::Admission.authorize_operator! if %w[accept reject waive risk-accept].include?(@action)
          service = Hive::TaskCapabilities::Revision.new(task: @resolver.call)
          payload = if @action == "show"
            service.show
          else
            expected = { expected_identity: parse(@options[:identity], "task identity"), expected_version: @options[:plan_version], expected_sha: @options[:sha] }
            raise Hive::UsageError, "mutations require --identity JSON --plan-version N --sha SHA" unless expected.values.none?(&:nil?)
            case @action
            when "propose"
              service.propose(**expected, selections: @options.fetch(:selections, []), verification_plans: parse(@options[:verification_plan] || "{}", "verification plan"),
                approval_references: @options.fetch(:approval_references, []), task_approvals: @options.fetch(:task_approvals, []), reason: @options[:reason] || "", checks: @options.fetch(:checks, []))
            when "accept" then service.accept(**expected, proposal_digest: @options[:proposal])
            when "reject" then service.reject(**expected, proposal_digest: @options[:proposal], reason: @options[:reason] || "")
            when "waive" then service.waive(**expected, reason: @options[:reason], checks: @options.fetch(:checks, []))
            when "risk-accept" then service.risk_accept(**expected, result_digest: @options[:result], finding_ids: @options.fetch(:findings, []), reason: @options[:reason])
            end
          end
          document = { "schema" => envelope_schema, "schema_version" => 1, "ok" => true, "action" => @action, "data" => payload }
          puts(@json ? JSON.generate(document) : JSON.pretty_generate(payload))
          document
        end
      end

      def envelope_schema = "hive-task-capabilities"
      def envelope_error_kind(error) = error.respond_to?(:reason) ? error.reason : Hive::CommandErrorKind.typed(error) || (error.is_a?(Hive::UsageError) ? "usage" : "error")
      def envelope_serialization_failure_policy = :raise

      private

      def parse(value, label)
        return nil if value.nil?
        result = value.is_a?(String) ? JSON.parse(value) : value
        raise Hive::UsageError, "#{label} must be a JSON object" unless result.is_a?(Hash)
        result
      rescue JSON::ParserError
        raise Hive::UsageError, "#{label} must be a JSON object"
      end
    end
  end
end

require "hive/cli_usage_contracts"
Hive::CliUsageContracts.declare("task-capabilities", { schema: "hive-task-capabilities", error_kind: "usage" })
