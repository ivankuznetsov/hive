require "digest"
require "erb"
require "fileutils"
require "json"
require "securerandom"
require "hive/artifact_firewall"
require "hive/markers"
require "hive/plan_review/plan_signals"
require "hive/secret_patterns"

module Hive
  module PlanReview
    class PlannerRevision
      MAX_CANDIDATE_BYTES = 1024 * 1024

      Result = Data.define(:outcome, :candidate_bytes, :candidate_digest, :route_receipt, :diagnostic) do
        def success? = outcome == "success"
      end

      class HiveRunner
        def initialize(task:, cfg:)
          @task = task
          @cfg = cfg
        end

        def call(prompt:, workspace:, output_path:, planner_identity:, timeout_sec:)
          require "hive/stages/base"

          profile = Hive::AgentProfiles.lookup(planner_identity.fetch("provider"), cfg: @cfg)
          protected = Hive::ArtifactFirewall::ORCHESTRATOR_OWNED.to_h do |name|
            [ name, File.join(@task.folder, name) ]
          end
          protected["meta.yml"] = @task.meta_yml_path
          protected["plan-review-current"] = File.join(@task.folder, "plan-review", "current.json")
          protected["revision-input"] = File.join(workspace, "input-plan.md")
          manifest = Hive::ArtifactFirewall::Manifest.new(
            root: @task.folder,
            protected_anchors: protected,
            permitted_writable_roots: [ workspace ],
            required_outputs: { "candidate-plan" => output_path }
          )
          snapshot = Hive::ArtifactFirewall.capture(manifest)
          result = Hive::Stages::Base.spawn_agent(
            @task,
            prompt:, add_dirs: [ workspace ], cwd: workspace,
            max_budget_usd: @cfg.dig("budget_usd", "plan"),
            timeout_sec:, log_label: "plan-review-revision",
            profile:, expected_output: output_path, status_mode: :output_file_exists,
            cfg: @cfg, model: planner_identity["model"], effort: planner_identity["effort"]
          )
          report = Hive::ArtifactFirewall.validate_and_restore(manifest, snapshot)
          if report.tampered?
            return {
              "status" => "terminal_failure",
              "diagnostic" => "planner revision modified protected artifacts: #{report.tampered_labels.join(', ')}"
            }
          end
          return { "status" => "retryable_failure", "diagnostic" => result[:error_message] } unless
            result[:status] == :ok && report.required_outputs_valid?

          {
            "status" => "success",
            "actual_route" => planner_identity.merge("model" => result.dig(:usage, :model).to_s).reject do |key, value|
              key == "model" && value.empty?
            end
          }
        rescue Hive::ArtifactFirewall::Error => e
          { "status" => "terminal_failure", "diagnostic" => e.message }
        end
      end

      def initialize(task:, cfg:, runner: HiveRunner.new(task:, cfg:))
        @task = task
        @cfg = cfg
        @runner = runner
      end

      def call(review_id:, plan_bytes:, findings:, planner_identity:, timeout_sec:)
        workspace = File.join(@task.folder, "plan-review", "reviews", review_id, "revision-workspace")
        FileUtils.mkdir_p(workspace, mode: 0o700)
        input_path = File.join(workspace, "input-plan.md")
        output_path = File.join(workspace, "candidate-output.md")
        File.binwrite(input_path, Hive::SecretPatterns.redact(plan_bytes.to_s))
        File.chmod(0o600, input_path)
        FileUtils.rm_f(output_path)
        prompt = render_prompt(
          input_path:, output_path:, findings:, review_id:, planner_identity:
        )
        observed = stringify(@runner.call(
          prompt:, workspace:, output_path:, planner_identity:, timeout_sec:
        ) || {})
        unless observed["status"] == "success"
          return result(observed.fetch("status", "terminal_failure"), nil, observed)
        end

        bytes = read_candidate!(output_path, workspace)
        result("success", bytes, observed)
      rescue InvalidRecord => e
        result("terminal_failure", nil, "diagnostic" => e.message)
      end

      private

      def render_prompt(input_path:, output_path:, findings:, review_id:, planner_identity:)
        source = File.read(File.expand_path("../../../templates/plan_revision_prompt.md.erb", __dir__))
        ERB.new(source, trim_mode: "-").result_with_hash(
          nonce: SecureRandom.hex(24), input_path:, output_path:, review_id:,
          findings_json: JSON.pretty_generate(Array(findings).map do |finding|
            finding.respond_to?(:to_h) ? finding.to_h : finding
          end),
          planner_identity_json: JSON.generate(planner_identity)
        )
      end

      def read_candidate!(path, workspace)
        expanded = File.expand_path(path)
        unless expanded.start_with?("#{File.expand_path(workspace)}#{File::SEPARATOR}")
          raise InvalidRecord, "candidate plan escapes revision workspace"
        end
        stat = File.lstat(expanded)
        raise InvalidRecord, "candidate plan is a symlink" if stat.symlink?
        raise InvalidRecord, "candidate plan is not a regular file" unless stat.file?

        bytes = File.binread(expanded, MAX_CANDIDATE_BYTES + 1)
        if bytes.bytesize > MAX_CANDIDATE_BYTES
          raise InvalidRecord, "candidate plan exceeds the size limit"
        end
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        raise InvalidRecord, "candidate plan is invalid UTF-8" unless text.valid_encoding?
        marker = Hive::Markers.current(expanded)
        unless marker.name == :complete
          raise InvalidRecord, "candidate plan must end with the COMPLETE plan marker"
        end
        text
      rescue Errno::ENOENT
        raise InvalidRecord, "planner did not publish candidate-plan.md"
      end

      def result(outcome, bytes, observed)
        Result.new(
          outcome: outcome.to_s,
          candidate_bytes: bytes,
          candidate_digest: bytes && Digest::SHA256.hexdigest(bytes.b),
          route_receipt: stringify(observed["actual_route"] || {}),
          diagnostic: Hive::SecretPatterns.redact(observed["diagnostic"].to_s)
        ).freeze
      end

      def stringify(value)
        return {} unless value.respond_to?(:to_h)

        value.to_h { |key, child| [ key.to_s, child ] }
      end
    end
  end
end
