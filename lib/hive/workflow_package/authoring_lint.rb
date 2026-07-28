require "digest"
require "hive/errors"
require "hive/workflow_package/lint_policy"
require "hive/workflow_package/authoring_lint/package_reader"
require "hive/workflow_package/authoring_lint/command_extractor"
require "hive/workflow_package/authoring_lint/observation_extractor"
require "hive/workflow_package/authoring_lint/finding_evaluator"

module Hive
  module WorkflowPackage
    class AuthoringLint
      class LintError < Hive::ConfigError
        attr_reader :result

        def initialize(result)
          @result = result
          super("Honeycomb authoring lint failed: #{result.errors.first&.message || 'unknown lint failure'}")
        end
      end

      Finding = Data.define(
        :rule_id, :severity, :path, :line, :column, :message,
        :review_required, :suppression_allowed, :fingerprint, :suppression_requested
      ) do
        def error? = severity == :error
        def warning? = severity == :warning

        def to_h
          {
            "rule_id" => rule_id, "severity" => severity.to_s, "path" => path,
            "line" => line, "column" => column, "message" => message,
            "review_required" => review_required,
            "suppression_allowed" => suppression_allowed,
            "fingerprint" => fingerprint,
            "suppression_requested" => suppression_requested
          }.compact.freeze
        end
      end

      Result = Data.define(:contract, :findings) do
        def errors = findings.select(&:error?)
        def warnings = findings.select(&:warning?)
        def valid? = errors.empty?
      end

      class ManifestSnapshot
        def initialize(manifest, snapshot:)
          @manifest = manifest
          @snapshot = snapshot
        end

        def data
          snapshot(:data)
        end

        def permissions
          snapshot(:permissions)
        end

        private

        def snapshot(name)
          variable = :"@#{name}"
          return instance_variable_get(variable) if instance_variable_defined?(variable)

          instance_variable_set(
            variable, @snapshot.call(@manifest.public_send(name))
          )
        end
      end
      class UnsafeYAML < StandardError; end

      private_constant(
        :PackageReader, :CommandExtractor, :ObservationExtractor,
        :FindingEvaluator, :ManifestSnapshot
      )

      def self.verify(root, manifest:, policy: nil)
        new(root, manifest: manifest, policy: policy || LintPolicy.load).verify
      rescue StandardError => e
        raise if e.is_a?(Hive::ConfigError)

        finding = Finding.new(
          rule_id: "policy.scanner-error", severity: :error, path: "manifest.yml",
          line: nil, column: nil, message: "local Honeycomb scanner failed closed",
          review_required: false, suppression_allowed: false,
          fingerprint: ::Digest::SHA256.hexdigest("policy.scanner-error"),
          suppression_requested: false
        )
        Result.new(contract: {}, findings: [ finding ].freeze).freeze
      end

      def self.verify!(...)
        result = verify(...)
        raise LintError, result unless result.valid?

        result
      end

      def initialize(root, manifest:, policy:)
        @root = File.expand_path(root)
        @manifest = manifest
        @policy = policy
        @finding_evaluator = FindingEvaluator.new(policy: policy)
      end

      def verify
        manifest = ManifestSnapshot.new(@manifest, snapshot: method(:deep_snapshot))
        findings = @finding_evaluator.evaluate(
          manifest: manifest,
          package_stage: lambda do |event_sink|
            PackageReader.new(@root, limits: @policy.limits)
                         .read(event_sink: event_sink)
          end,
          command_stage: lambda do |files, event_sink|
            CommandExtractor.new(manifest: manifest, limits: @policy.limits)
                            .extract(files, event_sink: event_sink)
          end,
          observation_stage: lambda do |commands, event_sink|
            ObservationExtractor.new(limits: @policy.limits)
                                .extract(commands, event_sink: event_sink)
          end
        )
        Result.new(contract: @policy.identity, findings: findings).freeze
      end

      private

      def deep_snapshot(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), snapshot|
            snapshot[deep_snapshot(key)] = deep_snapshot(child)
          end.freeze
        when Array
          value.map { |child| deep_snapshot(child) }.freeze
        when String
          value.dup.freeze
        else
          value
        end
      end
    end
  end
end
