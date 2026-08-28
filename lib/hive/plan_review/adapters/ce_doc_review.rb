require "digest"
require "erb"
require "fileutils"
require "json"
require "securerandom"
require "timeout"
require "hive/agent_limit"
require "hive/agent_profiles"
require "hive/agent_support"
require "hive/agent_skills"
require "hive/artifact_firewall"
require "hive/config"
require "hive/plan_review/adapters/base"
require "hive/plan_review/disposable_worktree"
require "hive/plan_review/result_parser"
require "hive/plan_review/route_resolver"
require "hive/plan_review/workspace_scope"
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
            scope = Hive::PlanReview::WorkspaceScope.launch_kwargs(
              profile:, workspace: cwd, role: request.kind, output_path:
            )
            custody = Hive::ArtifactFirewall::AgentCustody.new(
              custody_manifest(cwd, output_path)
            )
            result = custody.call do
              Hive::Stages::Base.spawn_agent(
                @task,
                prompt:,
                # cwd is a disposable detached checkout, so one directory
                # supplies both repository context and the write boundary.
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
                effort: request.reviewer["effort"],
                **scope
              )
            end
            tampered = custody.report&.tampered_labels.to_a
            unless tampered.empty?
              return {
                "status" => "terminal_failure",
                "diagnostic" => "reviewer modified protected artifacts: #{tampered.join(', ')}"
              }
            end
            normalize_result(result, request)
          rescue Hive::ArtifactFirewall::Error => error
            { "status" => "terminal_failure", "diagnostic" => error.message }
          rescue Hive::AgentError => error
            {
              "status" => "retryable_failure", "diagnostic" => error.message,
              "actual_route" => request.reviewer
            }
          end

          # Capability checks must use the same project profile as the launch
          # below. OpenCode uses native plugins plus any explicit project
          # plugin selection, so the probe must resolve that effective setup.
          def capability_probe(agent:, invocation:, project_root:)
            profile = Hive::AgentProfiles.lookup(agent, cfg: @cfg)
            status, message = profile.verify_skill(invocation, project_root:)
            {
              "status" => status == :present ? "present" : "unsupported",
              "diagnostic" => message
            }
          rescue StandardError => e
            { "status" => "unsupported", "diagnostic" => e.message }
          end

          private

          def normalize_result(result, request)
            status = if result[:status] == :ok
              "ok"
            elsif result[:timed_out]
              "timeout"
            elsif result[:error_reason].to_s.match?(/limit|quota|retry_after/) ||
                  result[:limit_text] || Hive::AgentLimit.from_limit?(result[:error_message])
              "provider_limit"
            else
              "retryable_failure"
            end
            served_model = result.dig(:usage, :model).to_s
            retry_at = result[:retry_at]
            if status == "provider_limit" && retry_at.to_s.empty?
              retry_at = Hive::AgentLimit.retry_after(text: result[:limit_text])
            end
            actual = {
              "provider" => request.reviewer["provider"],
              "route" => request.reviewer["route"],
              "effort" => request.reviewer["effort"],
              "model" => request.reviewer["model"],
              "family" => request.reviewer["family"]
            }
            unless served_model.empty?
              actual["model"] = served_model
              actual.delete("family")
              actual = RouteResolver.attest_observed_identity(
                requested: request.reviewer, actual:
              )
            end
            {
              "status" => status,
              "diagnostic" => result[:error_message],
              "retry_at" => retry_at,
              "actual_route" => actual
            }
          end

          # Hive journals the review attempt itself — stage entry, agent
          # session, projection checkpoints — while the reviewer is running.
          # Those writes land in the task's own bookkeeping files, so holding
          # them under the firewall made every review fail with "reviewer
          # modified protected artifacts: task-journal.jsonl,
          # task-projection.json" for edits the reviewer never made.
          #
          # They stay protected everywhere else (the execute-stage firewall is
          # untouched); here they are excluded because hive is the one writing
          # them during this exact window. What the reviewer must not touch —
          # plan.md, meta.yml, and every existing plan-review record — is still
          # anchored below.
          ORCHESTRATOR_JOURNALS = %w[task-journal.jsonl task-projection.json].freeze

          # Review history is append-only. Keep every record in one custody
          # transaction so validation failure cannot skip restoration of a
          # later batch. Manifest admission remains hard-bounded.
          def custody_manifest(workspace, output_path)
            anchored = Hive::ArtifactFirewall::ORCHESTRATOR_OWNED - ORCHESTRATOR_JOURNALS
            core = anchored.to_h do |name|
              [ name, File.join(@task.folder, name) ]
            end
            core["meta.yml"] = @task.meta_yml_path
            core["review-input"] = File.join(workspace, "plan.md")
            review_root = File.join(@task.folder, "plan-review")
            if File.directory?(review_root) && !File.symlink?(review_root)
              Dir.glob(File.join(review_root, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
                next if %w[. ..].include?(File.basename(path))
                next unless File.file?(path) || File.symlink?(path)

                relative = path.delete_prefix("#{review_root}/")
                core["plan-review/#{relative}"] = path
              end
            end
            writable_roots = [ workspace ]
            required_outputs = { "review-result" => output_path }
            manifest_entries = core.length + writable_roots.uniq.length +
                               required_outputs.length
            Hive::ArtifactFirewall::Manifest.new(
              root: @task.folder, protected_anchors: core,
              permitted_writable_roots: writable_roots,
              required_outputs: required_outputs,
              max_entries: [ manifest_entries, Hive::ArtifactFirewall::MAX_ENTRIES ].max
            )
          end
        end

        def initialize(runner:, capability_probe: nil,
                       capability_resolver: Hive::AgentSkills.method(:capability))
          @runner = runner
          @capability_probe = capability_probe ||
            if runner.respond_to?(:capability_probe)
              runner.method(:capability_probe)
            else
              method(:default_capability_probe)
            end
          @capability_resolver = capability_resolver
        end

        # Cheap preflight used by the orchestrator while an unsupported route
        # is parked. It deliberately avoids disposable-worktree construction,
        # immutable snapshot copies, and reviewer launch.
        def probe_capability(kind:, reviewer:, project_root:)
          return { "status" => "present", "diagnostic" => nil } if
            kind.to_s == "adversarial"

          provider = reviewer.fetch("provider")
          support = Hive::AgentSupport.for(provider)
          return support.plan_review_capability if support&.respond_to?(:plan_review_capability)

          contract = @capability_resolver.call(CAPABILITY, provider)
          stringify(@capability_probe.call(
            agent: provider,
            invocation: contract.invocation,
            project_root:
          )).merge("invocation" => contract.invocation)
        rescue KeyError, Hive::ConfigError => e
          { "status" => "unsupported", "diagnostic" => e.message }
        end

        def call(request)
          runner_result = nil
          disposable = nil
          disposable_worktree = nil
          validate_snapshot!(request)
          capability = probe_capability(
            kind: request.kind, reviewer: request.reviewer,
            project_root: request.project_root
          )
          if capability.fetch("status") != "present"
            return result(
              "unsupported",
              diagnostic: capability["diagnostic"],
              route_receipt: route_receipt(request, capability_result: capability.fetch("status"))
            )
          end

          before_digest = request.plan_digest
          disposable_worktree = DisposableWorktree.new(project_root: request.project_root)
          disposable = prepare_disposable(request, disposable_worktree)
          disposable_plan = File.join(disposable, "plan.md")
          snapshot_bytes = File.binread(disposable_plan)
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
          unless File.binread(disposable_plan) == snapshot_bytes
            return result(
              "terminal_failure",
              diagnostic: "reviewer mutated the immutable disposable plan snapshot",
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
          bytes = File.binread(output_path, ResultParser::MAX_BYTES + 1)
          parsed = ResultParser.parse(
            bytes,
            expected: {
              "attempt_id" => request.attempt_id,
              "plan_digest" => request.plan_digest,
              "policy_fingerprint" => request.policy_fingerprint
            },
            snapshot_bytes:
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
          result(
            "timeout", diagnostic: "plan review adapter timed out",
            route_receipt: route_receipt(request)
          )
        rescue Hive::AgentError => e
          result(
            "retryable_failure", diagnostic: e.message,
            route_receipt: route_receipt(request)
          )
        rescue StaleObservation, InvalidRecord, Hive::ConfigError => e
          actual = runner_result.is_a?(Hash) ? runner_result["actual_route"] : nil
          result(
            "terminal_failure", diagnostic: e.message,
            route_receipt: route_receipt(request, actual:)
          )
        rescue SystemCallError, IOError => e
          result("terminal_failure", diagnostic: "plan review adapter filesystem failure: #{e.message}")
        ensure
          disposable_worktree&.cleanup
        end

        private

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

        def prepare_disposable(request, disposable_worktree)
          root = request.output_directory
          FileUtils.mkdir_p(root, mode: 0o700)
          status = File.lstat(root)
          raise InvalidRecord, "plan review output directory is a symlink" if status.symlink?
          raise InvalidRecord, "plan review output path is not a directory" unless status.directory?

          path = disposable_worktree.create
          plan_copy = File.join(path, "plan.md")
          bytes = Hive::SecretPatterns.redact(File.binread(request.plan_path))
          File.binwrite(plan_copy, bytes)
          File.chmod(0o600, plan_copy)
          path
        end

        def render_prompt(request, disposable, output_path, capability)
          template = case request.kind
          when "adversarial" then "plan_review_adversarial_prompt.md.erb"
          when "verification" then "plan_review_verification_prompt.md.erb"
          else "plan_review_prompt.md.erb"
          end
          source = File.read(File.expand_path("../../../../templates/#{template}", __dir__))
          ERB.new(source, trim_mode: "-").result_with_hash(
            skill_invocation: request.kind == "adversarial" ? nil : capability.fetch("invocation"),
            nonce: SecureRandom.hex(24),
            plan_path: File.join(disposable, "plan.md"),
            project_root: disposable,
            output_path:,
            level: request.level,
            required_coverage_json: JSON.generate(request.required_coverage),
            attempt_id: request.attempt_id,
            plan_digest: request.plan_digest,
            policy_fingerprint: request.policy_fingerprint,
            verification_findings_json: JSON.pretty_generate(request.verification_findings)
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
          actual = stringify(actual)
          independent, reason = RouteResolver.independence(request.planner_identity, actual)
          {
            "role" => request.kind,
            "requested" => request.reviewer,
            "actual" => actual,
            "capability_result" => capability_result,
            "independence_verified" => independent,
            "independence_reason" => reason
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
