require "hive/task_capabilities/result_store"
require "hive/task_capabilities/actor_runner"
require "hive/stages/review/ci_fix"
require "hive/stages/review/browser_test"
require "hive/agent_git_gate"
require "hive/invoked_binary"

module Hive
  module TaskCapabilities
    # An attachment to Review, not a scheduler. Commands and independent actors
    # produce the same contract; only QA's behavior requirement is special.
    class Verification
      ENVIRONMENT_KEYS = %w[PATH LANG LC_ALL TZ BUNDLE_GEMFILE BUNDLE_PATH NODE_ENV RAILS_ENV].freeze
      PROPOSAL_KEYS = (Result::IDENTITY_KEYS + %w[state applicability evidence findings reason]).freeze

      def self.environment(plan: nil, commands: [])
        commands = plan.data.fetch("bindings").flat_map { |binding| binding.fetch("checks", []).filter_map { |check| check["command"] } } if plan
        executables = commands.filter_map { |command| Shellwords.split(command).first }.uniq.sort.reject { |program| program.include?("/") && !File.absolute_path?(program) }.to_h do |program|
          path = Hive::InvokedBinary.which(program)
          [ program, path && { "path" => File.realpath(path), "sha256" => ::Digest::SHA256.file(path).hexdigest } ]
        end
        { "platform" => RUBY_PLATFORM, "ruby" => RUBY_VERSION, "engine" => RUBY_ENGINE,
          "runtime_digest" => ::Digest::SHA256.file(RbConfig.ruby).hexdigest,
          "executables" => executables,
          "variables" => ENVIRONMENT_KEYS.to_h { |key| [ key, Result.digest(ENV[key]) ] } }
      end

      def self.check_identity(plan:, binding:, check:, context:, sha:, environment:)
        { "schema_version" => 1, "task" => plan.data.fetch("task"), "execution_plan_digest" => plan.digest,
          "capability_id" => binding.fetch("id"), "check_id" => check.fetch("id"),
          "parent_attempt_id" => context.attempt_id, "spawn_id" => nil,
          "evaluated_sha" => sha, "check_digest" => Result.check_digest(binding, check),
          "environment_digest" => Result.digest(environment), "kind" => check.fetch("kind"),
          "claim" => check.fetch("claim"), "runner" => check.fetch("runner", {}) }
      end

      # Existing CI is usable only when the controller observed its clean
      # before/after revision and its full runner configuration matches.
      def self.ci_observations(plan:, cfg:, context:, sha:, environment:, output:)
        return {} unless plan && context
        plan.data.fetch("bindings").each_with_object({}) do |binding, results|
          binding.fetch("checks", []).each do |check|
            runner = check["runner"]
            next unless check["provider"] == "ci" && runner && runner["type"] == "command" &&
              check["command"] == cfg.dig("review", "ci", "command") &&
              runner["timeout_sec"] == (cfg.dig("timeout_sec", "review_ci") || 600) &&
              runner["idle_timeout_sec"] == cfg.dig("timeout_sec", "review_ci_idle") &&
              runner["max_output_bytes"] == (cfg.dig("review", "ci", "max_log_bytes") || 262_144) && runner["environment"] == environment
            identity = check_identity(plan: plan, binding: binding, check: check, context: context, sha: sha, environment: environment)
            results[[ binding.fetch("id"), check.fetch("id") ]] = Result.command(identity, exit_status: 0, output: output.to_s)
          end
        end
      end

      # Capture runner configuration once. Retry never consults live CI/browser
      # settings to broaden or replace a planned check.
      def self.pin_runner(check, binding:, cfg:, project_root:)
        runner = { "environment" => environment, "command" => check["command"], "provider" => check["provider"],
          "configuration" => binding.slice("actor", "actor_route", "actor_fingerprint", "permissions", "targets", "budget_usd", "timeout_sec", "approval_reference"),
          "timeout_sec" => binding["timeout_sec"] || cfg.dig("timeout_sec", "review_ci") || 600,
          "idle_timeout_sec" => cfg.dig("timeout_sec", "review_ci_idle"),
          "max_output_bytes" => cfg.dig("review", "ci", "max_log_bytes") || 262_144 }
        if binding["actor"]
          runner["type"] = "actor"
        elsif check["provider"] == "browser"
          options = cfg.dig("review", "browser_test") || {}
          runner.merge!("type" => "actor", "browser" => options)
          if options.fetch("prompt_template", "browser_test_prompt.md.erb") != "browser_test_prompt.md.erb"
            return runner.merge("type" => "unavailable", "reason" => "custom browser prompt requires an explicit configured verification check; its requirements cannot be inferred from the legacy output template")
          end
          profile = Hive::AgentProfiles.lookup(options["agent"] || "claude", cfg: cfg)
          args = Hive::Stages::Base.model_launch_arguments(cfg, "review_browser", profile,
            current: Hive::Stages::Base.model_routing_current(options))
          model = args[:routing_arguments]&.model || args[:model] || cfg.dig(profile.name.to_s, "model")
          provider, model = Hive::AgentSupport.for(profile)&.execution_identity(model)
          actor = { "profile" => profile.name.to_s, "provider" => provider, "model" => model }
          effort = args[:routing_arguments]&.effort || args[:effort]
          actor["effort"] = effort if effort
          Definition.actor(actor, label: "browser verification")
          actor_binding = { "id" => binding.fetch("id"), "stage" => binding.fetch("stage"),
            "actor" => actor, "actor_fingerprint" => Hive::WorkflowPackage::Configuration.profile_fingerprint(profile),
            "actor_route" => Hive::ProviderRouting::Configuration.capability_route(cfg: cfg, actor: actor),
            "permissions" => options["permissions"] || "read-only",
            "targets" => [ "capability-source-#{binding.fetch('id')}-#{check.fetch('id')}" ],
            "budget_usd" => cfg.dig("budget_usd", "review_browser") || 25,
            "timeout_sec" => cfg.dig("timeout_sec", "review_browser") || 900,
            "skill" => Hive::Stages::Review::BrowserTest::SKILL }
          actor_binding["skill_identity"] = Admission.skill_identity(actor_binding, project_root: project_root, cfg: cfg)
          runner["actor_binding"] = actor_binding
        else
          runner["type"] = check["command"] ? "command" : "unavailable"
        end
        runner
      rescue Hive::ConfigError, Admission::Error => error
        runner.merge("type" => "unavailable", "reason" => error.message)
      end

      def initialize(task:, cfg:, worktree_path:, context: Hive::Attempts::Context.current,
                     session: nil, budget_usd: nil, timeout_sec: nil)
        @task, @cfg, @worktree, @context = task, cfg, worktree_path, context
        @plan = Store.new(task.folder).current
        @results = ResultStore.new(task.folder)
        @owned_session = session.nil?
        @session = session
        @budget, @timeout = budget_usd, timeout_sec
      end

      def run!(existing_results: {})
        return nil unless @plan
        unless @context
          raise Admission::Error, "adopted verification requires a durable parent attempt; run this task with --durable"
        end
        @session ||= ActorRunner::Session.new(budget_usd: @budget, timeout_sec: @timeout, parent: @context)
        environment = self.class.environment(plan: @plan)
        sha = git!(:head_oid).strip
        dirty = !git!(:status).empty?
        @plan.data.fetch("bindings").select { |binding| binding["kind"] == "verification" && binding["stage"] == "review" }.each do |binding|
          completed = {}
          ordered_checks(binding.fetch("checks")).each do |check|
            current = @results.current(binding: binding, check: check, plan: @plan, sha: sha, environment: environment)
            if !dirty && %w[passed not-applicable].include?(current["state"])
              completed[check.fetch("id")] = current.fetch("state")
              next
            end
            identity = self.class.check_identity(plan: @plan, binding: binding, check: check, context: @context, sha: sha, environment: environment)
            runner = check["runner"] || {}
            reason = if dirty
              "verification requires a clean implementation worktree; commit or restore changes before retrying"
            elsif runner["environment"] != environment
              "verification environment changed; restore the pinned environment or accept a revised execution plan"
            elsif check.fetch("depends_on", []).any? { |id| !%w[passed not-applicable].include?(completed[id]) }
              "verification prerequisites have not passed"
            end
            result = if reason
              record(identity, "blocked", reason: reason)
            else
              record(identity, "running", reason: "check started in its durable parent attempt")
              evaluate(binding, check, identity, existing_results[[ binding.fetch("id"), check.fetch("id") ]])
            end
            @results.accept(result)
            completed[check.fetch("id")] = result.state
          end
        end
        @results.aggregate(plan: @plan, sha: git!(:head_oid).strip, environment: self.class.environment(plan: @plan))
      ensure
        @session&.close if @owned_session
        @session = nil if @owned_session
      end

      private

      def git!(operation)
        result = Hive::AgentGitGate.read(@worktree, operation)
        raise Result::Invalid, "verification Git #{operation} unavailable" unless result.success?
        result.stdout
      end

      def ordered_checks(checks)
        remaining = checks.dup
        ordered = []
        until remaining.empty?
          ready = remaining.select { |check| (check.fetch("depends_on", []) - ordered.map { |item| item.fetch("id") }).empty? }
          raise Result::Invalid, "verification check dependencies are invalid" if ready.empty?
          ordered.concat(ready)
          remaining -= ready
        end
        ordered
      end

      def record(identity, state, reason: nil, evidence: [], findings: [], applicability: {})
        result = Result.new(identity.merge("state" => state, "reason" => reason, "evidence" => evidence,
          "findings" => findings, "applicability" => applicability))
        @results.accept(result) if state == "running"
        result
      end

      def evaluate(binding, check, identity, existing)
        before = git!(:head_oid).strip
        return record(identity, "blocked", reason: "implementation changed before verification") unless before == identity.fetch("evaluated_sha") && git!(:status).empty?
        result = if existing
          unless existing.is_a?(Result) || existing.is_a?(Hive::Stages::Review::BrowserTest::Result)
            raise Result::Invalid, "existing check evidence must be a controller result"
          end
          accept_observation(existing, identity)
        else
          case check.dig("runner", "type")
          when "command" then command_result(check, identity)
          when "actor" then actor_result(binding, check, identity)
          else record(identity, "blocked", reason: check.dig("runner", "reason") || "selected verification runner unavailable; configure a concrete verification plan")
          end
        end
        unless git!(:head_oid).strip == before && git!(:status).empty? && self.class.environment(plan: @plan) == check.dig("runner", "environment")
          return record(identity, "stale", reason: "implementation revision, worktree bytes or environment changed during verification")
        end
        result
      rescue Admission::Error, Result::Invalid, Hive::Artifacts::OutcomeEvidence::StoreError, JSON::ParserError, KeyError, SystemCallError => error
        record(identity, "blocked", reason: "verification unavailable or proposal rejected: #{error.message}".byteslice(0, 12_000).scrub)
      end

      def command_result(check, identity)
        runner = check.fetch("runner")
        timeout = [ runner.fetch("timeout_sec"), @session.remaining_timeout ].compact.min
        return record(identity, "blocked", reason: "parent verification deadline exhausted or cancelled") if @session.cancelled? || !timeout.positive?
        run = Hive::Stages::Review::CiFix.run_ci_once(check.fetch("command"), @worktree,
          runner.fetch("max_output_bytes"), timeout, idle_timeout_sec: runner["idle_timeout_sec"], cancelled: @session.method(:cancelled?))
        return record(identity, "blocked", reason: run.reason) if run.is_a?(Hive::Stages::Review::CiFix::CommandError)
        return record(identity, "blocked", reason: "parent verification was cancelled") if @session.cancelled?
        return record(identity, "blocked", reason: "verification command exited without an exit status") unless run.exit_code.is_a?(Integer)
        Result.command(identity, exit_status: run.exit_code, output: run.combined)
      end

      def actor_result(binding, check, identity)
        actor_binding = check.dig("runner", "actor_binding") || binding
        target = actor_binding.fetch("targets").first
        raise Admission::Error, "verification actor requires one exact approved source snapshot target" unless target && actor_binding.fetch("targets").one?
        destination = File.join(@task.folder, target)
        snapshot = Hive::AgentGitGate.materialize(repository_path: @worktree, oid: identity.fetch("evaluated_sha"),
          destination: destination, destination_root: @task.folder)
        prompt = "Independently verify this check against the exact source snapshot in your current directory. " \
          "#{actor_binding.dig('skill_identity', 'invocation')} #{actor_binding['instruction_content']} " \
          "Use only the approved tools, commands and local targets; do not request credentials or scan external targets. " \
          "Screenshots/recordings are optional; document or terminal outcome proof is sufficient. " \
          "Return only JSON with the supplied identity plus state (passed, failed, blocked, not-applicable), reason, applicability, evidence and findings. " \
          "Evidence must use Hive outcome proof descriptors (kind, summary, claims=[check_id], source with type=task/name/source_sha, representations with role/media_type/path/sha256/bytes), referencing existing task-relative files. " \
          "Failed checks need actionable findings with stable id, severity (high/medium/low), summary and details. N/A needs reason and evidence. " \
          "Identity: #{Hive::WorkflowPackage::CanonicalJSON.generate(identity.slice(*Result::IDENTITY_KEYS))}. " \
          "Planned check: #{Hive::WorkflowPackage::CanonicalJSON.generate(check.reject { |key, _| key == 'runner' })}"
        raw = ActorRunner.new(task: @task, cfg: @cfg, session: @session, context: @context).run(actor_binding, prompt: prompt)
        identity = identity.merge("spawn_id" => raw.fetch(:capability_spawn_id))
        unless raw[:status] == :ok
          return record(identity, "blocked", reason: "selected verification actor unavailable: #{raw[:error_reason] || raw[:error_message] || raw[:status]}")
        end
        proposal = JSON.parse(raw.fetch(:final_message), object_class: Hive::Artifacts::OutcomeEvidence::Document::StrictHash, allow_duplicate_key: false)
        accept_observation(proposal, identity)
      rescue Hive::AgentGitGate::Error, Admission::Error, Result::Invalid, Hive::Artifacts::OutcomeEvidence::StoreError, JSON::ParserError, KeyError, TypeError, SystemCallError => error
        record(identity, "blocked", reason: "verification actor or proposal unavailable: #{error.message}".byteslice(0, 12_000).scrub)
      ensure
        if snapshot
          Hive::AgentGitGate.remove_materialization(repository_path: @worktree,
            destination: destination, destination_root: @task.folder)
        end
      end

      def accept_observation(proposal, identity)
        proposal = Hive::Stages::Review::BrowserTest.verification_proposal(proposal) if proposal.is_a?(Hive::Stages::Review::BrowserTest::Result)
        if proposal.is_a?(Result)
          unless Result::IDENTITY_KEYS.all? { |key| proposal.data[key] == identity.fetch(key) } && proposal.data["runner"] == identity.fetch("runner")
            raise Result::Invalid, "existing check evidence belongs to another revision, configuration, environment or attempt"
          end
          raise Result::Invalid, "existing check observation is incomplete" unless %w[passed failed blocked not-applicable].include?(proposal.state)
          return proposal
        end
        unless proposal.is_a?(Hash) && (proposal.keys - PROPOSAL_KEYS).empty? && Result::IDENTITY_KEYS.all? { |key| proposal[key] == identity.fetch(key) }
          raise Result::Invalid, "verification proposal identity or schema does not match the planned check"
        end
        state = proposal.fetch("state")
        raise Result::Invalid, "agent proposal is not a completed check observation" unless %w[passed failed blocked not-applicable].include?(state)
        evidence = proposal.fetch("evidence")
        raise Result::Invalid, "verification proposal evidence must be an array" unless evidence.is_a?(Array)
        missing_capture = false
        proofs = evidence.filter_map do |proof|
          if proof.is_a?(Hash) && %w[screenshot video].include?(proof["kind"])
            metadata = Hive::Artifacts::OutcomeEvidence::Proof.admit_metadata!(proof,
              task_folder: @task.folder, expected_head: identity.fetch("evaluated_sha"))
            begin
              metadata.fetch("representations").each { |item| File.lstat(File.join(@task.folder, item.fetch("path"))) }
            rescue Errno::ENOENT
              missing_capture = true
              next
            end
          end
          admitted = Hive::Artifacts::OutcomeEvidence::Contract.verification!(proof,
            task_folder: @task.folder, check_id: identity.fetch("check_id"), expected_head: identity.fetch("evaluated_sha"))
          admitted = Hive::Artifacts::OutcomeEvidence::Proof.materialize!(admitted,
            task_folder: @task.folder, expected_head: identity.fetch("evaluated_sha"),
            destination_root: "capability-evidence-#{SecureRandom.uuid}")
          { "kind" => "outcome", "evaluated_sha" => identity.fetch("evaluated_sha"), "proof" => admitted }
        end
        reason = proposal.fetch("reason")
        reason = [ reason, "optional screenshot/video capture unavailable" ].compact.join("; ").byteslice(0, 12_000).scrub if missing_capture
        record(identity, state, reason: reason, evidence: proofs,
          findings: proposal.fetch("findings"), applicability: proposal.fetch("applicability"))
      end
    end
  end
end
