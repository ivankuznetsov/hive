require "digest"
require "erb"
require "fileutils"
require "json"
require "securerandom"
require "timeout"
require "hive/agent_profiles"
require "hive/agent_skills"
require "hive/plan_review/adapters/base"
require "hive/plan_review/result_parser"
require "hive/secret_patterns"

module Hive
  module PlanReview
    module Adapters
      class CeDocReview
        CAPABILITY = "ce-doc-review".freeze
        OUTPUT_BASENAME = "hive-plan-review-result.json".freeze

        class HiveRunner
          def initialize(task:, cfg:)
            @task = task
            @cfg = cfg
          end

          def call(prompt:, cwd:, output_path:, request:, **)
            require "hive/stages/base"

            profile = Hive::AgentProfiles.lookup(request.reviewer.fetch("provider"), cfg: @cfg)
            result = Hive::Stages::Base.spawn_agent(
              @task,
              prompt:,
              add_dirs: [ cwd ],
              cwd:,
              max_budget_usd: @cfg.dig("budget_usd", "plan"),
              timeout_sec: request.timeout_sec,
              log_label: "plan-review-#{request.kind}",
              profile:,
              expected_output: output_path,
              status_mode: :output_file_exists,
              cfg: @cfg,
              model: request.reviewer["model"],
              effort: request.reviewer["effort"]
            )
            normalize_result(result, request)
          end

          private

          def normalize_result(result, request)
            status = if result[:status] == :ok
              "ok"
            elsif result[:timed_out]
              "timeout"
            elsif result[:error_reason].to_s.match?(/limit|quota|retry_after/)
              "provider_limit"
            else
              "retryable_failure"
            end
            served_model = result.dig(:usage, :model) || request.reviewer["model"]
            {
              "status" => status,
              "diagnostic" => result[:error_message],
              "retry_at" => result[:retry_at],
              "actual_route" => request.reviewer.merge("model" => served_model.to_s)
            }
          end
        end

        def initialize(runner:, capability_probe: method(:default_capability_probe),
                       capability_resolver: Hive::AgentSkills.method(:capability))
          @runner = runner
          @capability_probe = capability_probe
          @capability_resolver = capability_resolver
        end

        def call(request)
          validate_snapshot!(request)
          capability = capability_for(request)
          if capability.fetch("status") != "present"
            return result(
              "unsupported",
              diagnostic: capability["diagnostic"],
              route_receipt: route_receipt(request, capability_result: capability.fetch("status"))
            )
          end

          before_digest = Digest::SHA256.file(request.plan_path).hexdigest
          disposable = prepare_disposable(request)
          output_path = File.join(disposable, OUTPUT_BASENAME)
          prompt = render_prompt(request, disposable, output_path, capability)
          runner_result = stringify(@runner.call(
            prompt:,
            cwd: disposable,
            output_path:,
            request:,
            capability:
          ) || {})
          after_digest = Digest::SHA256.file(request.plan_path).hexdigest
          if before_digest != after_digest
            return result(
              "terminal_failure",
              diagnostic: "reviewer mutated the immutable plan snapshot",
              route_receipt: route_receipt(request, actual: runner_result["actual_route"])
            )
          end

          status = normalize_status(runner_result["status"])
          unless status == "success"
            return result(
              status,
              diagnostic: runner_result["diagnostic"],
              retry_at: runner_result["retry_at"],
              route_receipt: route_receipt(request, actual: runner_result["actual_route"])
            )
          end
          validate_output!(output_path, disposable)
          parsed = ResultParser.parse(
            File.binread(output_path),
            expected: {
              "attempt_id" => request.attempt_id,
              "plan_digest" => request.plan_digest,
              "policy_fingerprint" => request.policy_fingerprint
            }
          )
          result(
            parsed.outcome,
            findings: parsed.findings,
            coverage: parsed.coverage,
            selected_lenses: parsed.selected_lenses,
            residual_evidence: parsed.residual_evidence,
            diagnostic: parsed.diagnostic,
            retry_at: parsed.retry_at,
            route_receipt: route_receipt(request, actual: runner_result["actual_route"])
          )
        rescue Timeout::Error
          result("timeout", diagnostic: "plan review adapter timed out")
        rescue StaleObservation, InvalidRecord => e
          result("terminal_failure", diagnostic: e.message)
        rescue SystemCallError, IOError => e
          result("terminal_failure", diagnostic: "plan review adapter filesystem failure: #{e.message}")
        end

        private

        def capability_for(request)
          return { "status" => "present", "diagnostic" => nil } if request.kind == "adversarial"

          contract = @capability_resolver.call(CAPABILITY, request.reviewer.fetch("provider"))
          stringify(@capability_probe.call(
            agent: request.reviewer.fetch("provider"),
            invocation: contract.invocation,
            project_root: request.project_root
          )).merge("invocation" => contract.invocation)
        rescue KeyError => e
          { "status" => "unsupported", "diagnostic" => e.message }
        end

        def default_capability_probe(agent:, invocation:, project_root:)
          profile = Hive::AgentProfiles.lookup(agent)
          status, message = profile.verify_skill(invocation, project_root:)
          {
            "status" => status == :present ? "present" : "unsupported",
            "diagnostic" => message
          }
        rescue StandardError => e
          { "status" => "unsupported", "diagnostic" => e.message }
        end

        def validate_snapshot!(request)
          status = File.lstat(request.plan_path)
          raise InvalidRecord, "plan review snapshot is a symlink" if status.symlink?
          raise InvalidRecord, "plan review snapshot is not a regular file" unless status.file?
          unless Digest::SHA256.file(request.plan_path).hexdigest == request.plan_digest
            raise StaleObservation, "plan review snapshot digest changed"
          end
        end

        def prepare_disposable(request)
          root = request.output_directory
          FileUtils.mkdir_p(root, mode: 0o700)
          status = File.lstat(root)
          raise InvalidRecord, "plan review output directory is a symlink" if status.symlink?
          raise InvalidRecord, "plan review output path is not a directory" unless status.directory?

          path = File.join(root, "disposable-#{request.attempt_id}")
          FileUtils.mkdir_p(path, mode: 0o700)
          plan_copy = File.join(path, "plan.md")
          bytes = Hive::SecretPatterns.redact(File.binread(request.plan_path))
          File.binwrite(plan_copy, bytes)
          File.chmod(0o600, plan_copy)
          path
        end

        def render_prompt(request, disposable, output_path, capability)
          template = request.kind == "adversarial" ?
            "plan_review_adversarial_prompt.md.erb" : "plan_review_prompt.md.erb"
          source = File.read(File.expand_path("../../../../templates/#{template}", __dir__))
          ERB.new(source, trim_mode: "-").result_with_hash(
            skill_invocation: request.kind == "adversarial" ? nil : capability.fetch("invocation"),
            nonce: SecureRandom.hex(24),
            plan_path: File.join(disposable, "plan.md"),
            output_path:,
            level: request.level,
            required_coverage_json: JSON.generate(request.required_coverage),
            attempt_id: request.attempt_id,
            plan_digest: request.plan_digest,
            policy_fingerprint: request.policy_fingerprint
          )
        end

        def validate_output!(path, disposable)
          expanded = File.expand_path(path)
          unless expanded.start_with?("#{File.expand_path(disposable)}#{File::SEPARATOR}")
            raise InvalidRecord, "plan review output escapes the disposable directory"
          end
          status = File.lstat(expanded)
          raise InvalidRecord, "plan review output is a symlink" if status.symlink?
          raise InvalidRecord, "plan review output is not a regular file" unless status.file?
        rescue Errno::ENOENT
          raise InvalidRecord, "plan review adapter did not publish its JSON result"
        end

        def normalize_status(value)
          case value.to_s
          when "ok", "success" then "success"
          when "timeout" then "timeout"
          when "provider_limit" then "provider_limit"
          when "unsupported" then "unsupported"
          when "terminal_failure" then "terminal_failure"
          else "retryable_failure"
          end
        end

        def route_receipt(request, actual: nil, capability_result: "present")
          actual = stringify(actual || request.reviewer)
          planner_family = request.planner_identity["family"].to_s
          reviewer_family = actual["family"].to_s
          independent = !planner_family.empty? && !reviewer_family.empty? && planner_family != reviewer_family
          {
            "role" => request.kind,
            "requested" => request.reviewer,
            "actual" => actual,
            "capability_result" => capability_result,
            "independence_verified" => independent,
            "independence_reason" => independent ? "different_model_family" : "same_or_unknown_model_family"
          }.freeze
        end

        def result(outcome, **attributes)
          attributes[:diagnostic] = Hive::SecretPatterns.redact(attributes[:diagnostic].to_s) if attributes[:diagnostic]
          Base::Result.new(outcome:, **attributes)
        end

        def stringify(value)
          return {} unless value.respond_to?(:to_h)

          value.to_h { |key, child| [ key.to_s, child ] }
        end
      end
    end
  end
end
