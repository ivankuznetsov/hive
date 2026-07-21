require "time"
require "tmpdir"
require "hive/commands/workflow/base"
require "hive/workflow_package/publisher"

module Hive
  module Commands
    class Workflow
      class Publish < Base
        SCHEMA = "hive-workflow-publish".freeze
        SHA256 = /\A[0-9a-f]{64}\z/

        class ValidationError < Hive::Error
          def exit_code = Hive::ExitCodes::USAGE
        end

        def initialize(name, project_root:, version:, json: false, dry_run: false,
                       expected_release_digest: nil, stdout: $stdout, publisher: nil, clock: nil)
          super(project_root: project_root, json: json, stdout: stdout)
          @name = name.to_s
          @version = version.to_s
          @dry_run = dry_run
          @expected_release_digest = expected_release_digest
          @clock = clock || -> { Time.now.utc }
          @publisher = publisher || Hive::WorkflowPackage::Publisher.new(
            @name, project_root: project_root, version: @version
          )
        end

        def call!
          validate_expected_digest!
          Dir.mktmpdir("hive-workflow-package-") do |root|
            @last_package = build_package(root)
            assert_expected_digest!(@last_package)
            return emit_validated(@last_package) if @dry_run

            result = @publisher.publish(@last_package)
            emit_lifecycle(@last_package, result)
          end
        end

        private

        def build_package(root)
          if @dry_run || !@publisher.respond_to?(:prepare)
            @publisher.package(destination: root)
          else
            @publisher.prepare(destination: root)
          end
        rescue Hive::WorkflowPackage::PackageError, Hive::ConfigError => e
          raise ValidationError, e.message
        end

        def validate_expected_digest!
          return if @expected_release_digest.nil?
          unless SHA256.match?(@expected_release_digest.to_s)
            raise ValidationError, "--expected-release-digest must be a lowercase SHA-256 digest"
          end
          return unless @dry_run

          raise ValidationError, "--expected-release-digest is for the confirmed real publication, not dry-run"
        end

        def assert_expected_digest!(package)
          return unless @expected_release_digest
          return if secure_equal?(@expected_release_digest, package.release_digest)

          raise ValidationError, "validated release digest changed; run dry-run and obtain confirmation again"
        end

        def emit_validated(package)
          validated_at = @clock.call.utc.iso8601
          payload = common_payload(package).merge(
            "state" => "validated", "freshness" => "not_checked", "validated_at" => validated_at
          )
          emit(payload, human_lines: [
            "hive: validated honeycomb/#{package.name}@#{package.version}",
            "release digest: #{package.release_digest}",
            "remote lifecycle: not checked"
          ])
        end

        def emit_lifecycle(package, result)
          payload = common_payload(package).merge(
            "state" => result.state, "freshness" => result.freshness,
            "observed_at" => result.observed_at, "pr_url" => result.pr_url,
            "warnings" => (package.warnings + result.warnings).uniq
          )
          label = result.state == "listed" ? "listed in the Honeycomb catalogue" : result.state.tr("_", " ")
          lines = [
            "hive: honeycomb/#{package.name}@#{package.version} is #{label}",
            "release digest: #{package.release_digest}",
            "freshness: #{result.freshness} at #{result.observed_at}"
          ]
          lines << "pull request: #{result.pr_url}" if result.pr_url
          emit(payload, human_lines: lines)
        end

        def common_payload(package)
          {
            "schema" => SCHEMA,
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
            "ok" => true, "name" => package.name, "version" => package.version,
            "package_digest" => package.package_digest,
            "release_digest" => package.release_digest,
            "warnings" => package.warnings
          }
        end

        def error_payload(error)
          extras = { "retryable" => retryable?(error) }
          if @last_package
            extras["package_digest"] = @last_package.package_digest
            extras["release_digest"] = @last_package.release_digest
            receipt = @publisher.receipt_for(@last_package) if @publisher.respond_to?(:receipt_for)
            if receipt
              extras["last_completed_step"] = receipt.last_completed_step
              extras["last_observed_state"] = receipt.observation["state"] if receipt.observation
              extras["pr_url"] = receipt.data["pr_url"] if receipt.data["pr_url"]
            end
          end
          Hive::Schemas::ErrorEnvelope.build(
            schema: SCHEMA, error: error, error_kind: error_kind(error), extras: extras
          )
        rescue StandardError
          Hive::Schemas::ErrorEnvelope.build(
            schema: SCHEMA, error: error, error_kind: error_kind(error),
            extras: { "retryable" => retryable?(error) }
          )
        end

        def error_kind(error)
          case error
          when ValidationError, Hive::WorkflowPackage::PackageError then "validation"
          when Hive::WorkflowPackage::PublishAuthenticationError then "authentication"
          when Hive::WorkflowPackage::PublishOfflineError, Hive::WorkflowPackage::CatalogueUnavailable then "offline"
          when Hive::WorkflowPackage::PublishConflict then "immutable_conflict"
          when Hive::WorkflowPackage::PublishAmbiguousError then "remote_ambiguous"
          when Hive::ConfigError then "configuration"
          else "internal"
          end
        end

        def retryable?(error)
          error.is_a?(Hive::WorkflowPackage::PublishOfflineError) ||
            error.is_a?(Hive::WorkflowPackage::CatalogueUnavailable) ||
            error.is_a?(Hive::WorkflowPackage::PublishAmbiguousError)
        end

        def secure_equal?(left, right)
          left.bytesize == right.bytesize &&
            left.bytes.zip(right.bytes).reduce(0) { |memo, (a, b)| memo | (a ^ b) }.zero?
        end

        def envelope_schema = SCHEMA
      end
    end
  end
end
