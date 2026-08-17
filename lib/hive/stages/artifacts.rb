require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "hive/claude_launcher"
require "hive/artifact_firewall"
require "hive/artifacts/capture_policy"
require "hive/artifacts/capture_toolkit"
require "hive/artifacts/outcome_evidence/contract"
require "hive/artifacts/outcome_evidence/identity"
require "hive/artifacts/outcome_evidence/store"
require "hive/atomic_file"
require "hive/markers"
require "hive/screenote/credential_store"
require "hive/screenote/mcp_config"
require "hive/screenote/oauth_client"
require "hive/stages/base"

module Hive
  module Stages
    module Artifacts
      module_function

      EVIDENCE_ROLES = %w[inference producer reviewer].freeze
      MAX_INFERENCE_ATTEMPTS = 2
      class RoleOutputError < Hive::Artifacts::OutcomeEvidence::StoreError; end
      DEFAULT_REVIEW_CAPABILITIES = {
        "proof_kinds" => Hive::Artifacts::OutcomeEvidence::Proof::KINDS,
        "temporal_video" => true
      }.freeze

      def run!(task, cfg)
        FileUtils.touch(task.state_file) unless File.exist?(task.state_file)
        run_outcome_evidence!(task, cfg || {})
      rescue Hive::Artifacts::OutcomeEvidence::Error, Hive::ArtifactFirewall::Error,
             Hive::Artifacts::BrowserGateway::GatewayError,
             Hive::Artifacts::CaptureMailbox::MailboxError,
             Hive::Artifacts::ManagedWebServer::ServerError,
             Hive::AgentError, Hive::ConfigError, KeyError => e
        Hive::Markers.set(
          task.state_file, :error, reason: "outcome_evidence_invalid",
          diagnostic: e.message.to_s.byteslice(0, 200).to_s.scrub
        )
        { commit: "error", status: :error }
      end

      def run_outcome_evidence!(task, cfg, identity_resolver: nil, store: nil,
                                capture_toolkit: nil)
        project = File.basename(task.project_root)
        identity_resolver ||= Hive::Artifacts::OutcomeEvidence::Identity.new(
          task: task, project: project
        )
        identity = identity_resolver.resolve
        store ||= Hive::Artifacts::OutcomeEvidence::Store.new(task: task, project: project)
        capture_toolkit ||= Hive::Artifacts::CaptureToolkit.new
        if store.accepted_for_identity?(identity)
          publish_complete_marker!(task, store.current)
          return { commit: action_for(:complete), status: :complete }
        end
        if store.blocked_for_identity?(identity)
          publish_blocked_marker!(task, store.current)
          return { commit: "error", status: :error }
        end

        requirement = store.requirement_for_identity(identity)
        review_context = if requirement && store.respond_to?(:review_context_for_identity)
          store.review_context_for_identity(identity) || {}
        else
          {}
        end
        unless requirement
          review_context = store.materialize_review_context!(
            identity: identity,
            source_root: task.worktree_path || task.project_root
          ) if store.respond_to?(:materialize_review_context!)
          requirement = infer_requirement!(
            task: task, cfg: cfg, identity: identity, store: store,
            review_context: review_context
          )
        end
        generation = requirement.fetch("generation")
        if store.accepted?(generation: generation)
          publish_complete_marker!(task, store.current)
          return { commit: action_for(:complete), status: :complete }
        end

        producer_profile = nil
        begin
          preflight_reviewer!(cfg, requirement.fetch("claims"))
          producer_profile = preflight_producer!(cfg, requirement.fetch("claims"))
        rescue Hive::ConfigError => e
          pointer = store.publish_blocked!(
            generation: generation, reason: "capability_blocked",
            failed_targets: requirement.fetch("claims").map { |claim| claim.fetch("id") },
            reviewer_reasons: [ e.message ], attempt_ids: []
          )
          publish_blocked_marker!(task, pointer)
          return { commit: "error", status: :error }
        end

        history = store.attempts(generation: generation).dup
        accepted = history.find { |attempt| attempt.fetch("status") == "accepted" }
        if accepted
          pointer = store.publish_current!(
            generation: generation, attempt_id: accepted.fetch("attempt_id")
          )
          publish_complete_marker!(task, pointer)
          return { commit: action_for(:complete), status: :complete }
        end

        max_recaptures = cfg.dig("artifacts", "evidence", "max_recaptures")
        max_recaptures = Hive::Config::DEFAULTS.dig(
          "artifacts", "evidence", "max_recaptures"
        ) if max_recaptures.nil?
        max_attempts = 1 + Integer(max_recaptures)

        loop do
          prior = history.last
          if prior&.fetch("status") == "blocked"
            return block_from_review!(task, store, requirement, history, prior)
          end
          if prior&.fetch("status") == "revise" &&
             unrecapturable_revision?(requirement, prior)
            return block_from_review!(task, store, requirement, history, prior)
          end
          if prior&.fetch("status") == "revise" && history.length >= max_attempts
            return block_from_review!(
              task, store, requirement, history, prior,
              reason: "recaptures_exhausted"
            )
          end

          revision = revision_guidance(requirement, prior)
          attempt_number = history.length + 1
          attempt_id = format("attempt-%02d-%s", attempt_number, SecureRandom.hex(8))
          writable_root = File.join(
            task.folder, "outcome-evidence", "work", generation, attempt_id
          )
          writable_relative_root = Pathname.new(writable_root)
            .relative_path_from(Pathname.new(task.folder)).to_s
          capture_tools = begin
            capture_toolkit.prepare!(
              kinds: requirement.fetch("claims").map { |claim| claim.fetch("proof_kind") },
              task_root: task.folder,
              source_root: task.worktree_path || task.project_root,
              source_sha: identity.fetch("implementation_head"),
              writable_root: writable_root,
              producer_profile: producer_profile
            )
          rescue Hive::ConfigError => e
            pointer = store.publish_blocked!(
              generation: generation, reason: "capability_blocked",
              failed_targets: revision.any? ? revision.map { |item| item.fetch("target_id") } :
                requirement.fetch("claims").map { |claim| claim.fetch("id") },
              reviewer_reasons: [ e.message ],
              attempt_ids: history.map { |item| item.fetch("attempt_id") }
            )
            publish_blocked_marker!(task, pointer)
            return { commit: "error", status: :error }
          end
          producer = nil
          replacements = begin
            producer_prompt = render_role_prompt(
              "artifacts_producer_prompt.md.erb", task,
              requirement_json: JSON.pretty_generate(requirement),
              prior_evidence_json: JSON.pretty_generate(prior ? prior.fetch("evidence") : []),
              revision_json: JSON.pretty_generate(revision),
              capture_tools_json: JSON.pretty_generate(capture_tools),
              writable_root: writable_root,
              writable_relative_root: writable_relative_root
            )
            producer = run_role!(
              role: "producer", task: task, cfg: cfg, prompt: producer_prompt,
              identity: identity, writable_root: writable_root,
              launch_environment: capture_toolkit.launch_environment,
              producer_add_dirs: capture_toolkit.producer_add_dirs,
              producer_permission_arguments: capture_toolkit.producer_permission_arguments,
              producer_runtime_policy: capture_toolkit.producer_runtime_policy
            )
            candidate = Array(producer.fetch(:output).fetch("evidence"))
            capture_toolkit.verify_captures!(candidate)
            ensure_producer_paths!(task, writable_root, candidate)
            store.retain_candidate!(
              generation: generation, attempt_id: attempt_id, evidence: candidate
            )
          ensure
            begin
              capture_toolkit.close if capture_toolkit.respond_to?(:close)
            ensure
              remove_producer_work!(task, writable_root)
            end
          end
          evidence = merge_candidate_evidence!(prior, replacements, revision)

          reviewer_prompt = render_role_prompt(
            "artifacts_reviewer_prompt.md.erb", task,
            requirement_json: JSON.pretty_generate(requirement),
            evidence_json: JSON.pretty_generate(evidence),
            review_context_json: JSON.pretty_generate(review_context)
          )
          reviewer = run_role!(
            role: "reviewer", task: task, cfg: cfg, prompt: reviewer_prompt,
            identity: identity
          )
          reviewer_output = reviewer.fetch(:output)
          unless reviewer_output.keys == [ "verdicts" ]
            raise Hive::Artifacts::OutcomeEvidence::StoreError,
                  "reviewer output must contain only verdicts"
          end
          review = reviewer_output.merge(
            "reviewer" => reviewer.fetch(:actor),
            "review_scope_hashes" => representation_hashes(evidence)
          )
          status = semantic_review_status!(review.fetch("verdicts"))
          diagnostic = if status == "accepted"
            nil
          else
            Array(review.fetch("verdicts")).filter_map do |verdict|
              verdict.fetch("reason") unless verdict.fetch("verdict") == "accepted"
            end.join("; ").byteslice(0, 16_384).to_s.scrub
          end
          attempt = store.append_attempt!(
            generation: generation, attempt_id: attempt_id,
            status: status, evidence: evidence,
            producer: producer.fetch(:actor), review: review,
            diagnostic: diagnostic
          )
          history << attempt

          if status == "accepted"
            pointer = store.publish_current!(generation: generation, attempt_id: attempt_id)
            publish_complete_marker!(task, pointer)
            return { commit: action_for(:complete), status: :complete }
          end
          if status == "blocked"
            return block_from_review!(task, store, requirement, history, attempt)
          end
        end
      end

      def infer_requirement!(task:, cfg:, identity:, store:, review_context:)
        repair = nil
        MAX_INFERENCE_ATTEMPTS.times do |index|
          prompt = render_role_prompt(
            "artifacts_inference_prompt.md.erb", task,
            identity_json: JSON.pretty_generate(identity),
            review_context_json: JSON.pretty_generate(review_context),
            repair_json: JSON.pretty_generate(repair || {})
          )
          begin
            inference = run_role!(
              role: "inference", task: task, cfg: cfg, prompt: prompt,
              identity: identity
            )
          rescue RoleOutputError => e
            raise if index + 1 >= MAX_INFERENCE_ATTEMPTS

            repair = {
              "validation_error" => e.message.to_s.byteslice(0, 1024).to_s.scrub,
              "previous_output" => nil
            }
            next
          end
          proposal = inference.fetch(:output)
          begin
            Hive::Artifacts::OutcomeEvidence::Contract.requirement!(
              implementation: identity, claims: proposal.fetch("claims"),
              exclusions: proposal.fetch("exclusions"),
              inference: inference.fetch(:actor)
            )
          rescue Hive::Artifacts::OutcomeEvidence::StoreError, KeyError => e
            raise if index + 1 >= MAX_INFERENCE_ATTEMPTS

            repair = {
              "validation_error" => e.message.to_s.byteslice(0, 1024).to_s.scrub,
              "previous_output" => proposal
            }
            next
          end

          return store.open_generation!(
            identity: identity,
            claims: proposal.fetch("claims"), exclusions: proposal.fetch("exclusions"),
            inference: inference.fetch(:actor),
            reviewer_capabilities: reviewer_capabilities(cfg)
          )
        end
      end

      def run_role!(role:, task:, cfg:, prompt:, identity:, writable_root: nil,
                    launch_environment: nil, producer_add_dirs: [],
                    producer_permission_arguments: nil, producer_runtime_policy: nil)
        role = role.to_s
        raise Hive::ConfigError, "unknown outcome-evidence role #{role.inspect}" unless EVIDENCE_ROLES.include?(role)

        actor_cfg = evidence_role_config(cfg, role)
        profile = Hive::Stages::Base.stage_profile(
          cfg, "artifacts", explicit_agent: actor_cfg["agent"] || cfg.dig("artifacts", "agent")
        )
        context_id = "#{role}-#{SecureRandom.hex(12)}"
        prompt = "Context identity: #{context_id}\n\n#{prompt}"
        FileUtils.mkdir_p(writable_root, mode: 0o700) if writable_root
        manifest = role_firewall_manifest(task, writable_root)
        agent_custody = Hive::ArtifactFirewall::AgentCustody.new(manifest)
        security = role_security_kwargs(
          role, task: task, cfg: cfg, profile: profile, actor_cfg: actor_cfg,
          writable_root: writable_root, producer_runtime_policy: producer_runtime_policy
        )
        launch_cfg = evidence_role_launch_config(cfg, actor_cfg)
        context = Hive::Attempts::Context.current
        launch_arguments = if context&.explicit_routing?
          { routing_arguments: nil }
        else
          Hive::Stages::Base.model_launch_arguments(
            cfg, "artifacts", profile,
            current: Hive::Stages::Base.model_routing_current(launch_cfg)
          )
        end
        routing = launch_arguments[:routing_arguments]
        launch_dirs = if role == "producer" && profile.workspace_write_supported?
          [ writable_root, *producer_add_dirs ].compact.uniq
        else
          [ task.folder, task.worktree_path ].compact.uniq
        end
        result = nil
        permission_arguments = if role == "producer" && profile.name == :codex
          producer_permission_arguments
        end
        begin
          result = Hive::Stages::Base.spawn_agent(
            task,
            prompt: prompt,
            add_dirs: launch_dirs,
            cwd: writable_root || task.worktree_path || task.folder,
            max_budget_usd: cfg.dig("budget_usd", "artifacts") || Hive::Config::DEFAULTS.dig("budget_usd", "artifacts"),
            timeout_sec: cfg.dig("timeout_sec", "artifacts") || Hive::Config::DEFAULTS.dig("timeout_sec", "artifacts"),
            log_label: "artifacts-#{role}-#{context_id}", profile: profile,
            status_mode: :exit_code_only, cfg: cfg,
            **launch_arguments,
            permission_arguments: permission_arguments,
            isolate_environment: true,
            launch_environment: launch_environment,
            agent_custody: agent_custody,
            **security
          )
        rescue Hive::AgentError => e
          report = agent_custody.report
          if report && !report.valid?
            raise Hive::Artifacts::OutcomeEvidence::StoreError,
                  "#{role} modified protected task state: #{report.diagnostic}"
          end

          raise Hive::Artifacts::OutcomeEvidence::StoreError,
                "#{role} agent failed before durable output: #{e.message}"
        ensure
          cleanup_producer_process_group(result) if role == "producer"
        end
        report = agent_custody.report
        if !report && result.is_a?(Hash) && result[:status] == :ok
          raise Hive::Artifacts::OutcomeEvidence::StoreError,
                "#{role} agent custody was not invoked"
        end
        if report && !report.valid?
          raise Hive::Artifacts::OutcomeEvidence::StoreError,
                "#{role} modified protected task state: #{report.diagnostic}"
        end
        unless result && result[:status] == :ok
          raise Hive::Artifacts::OutcomeEvidence::StoreError,
                "#{role} agent did not return a successful durable output"
        end
        if result[:final_message_truncated] == true
          raise Hive::Artifacts::OutcomeEvidence::StoreError,
                "#{role} output was truncated and cannot establish durable evidence"
        end
        resolved = Hive::Artifacts::OutcomeEvidence::Identity.new(
          task: task, project: File.basename(task.project_root)
        ).resolve
        unless resolved == identity
          raise Hive::Artifacts::OutcomeEvidence::StoreError,
                "#{role} changed the frozen implementation source"
        end

        {
          actor: {
            "context_id" => context_id,
            "agent" => profile.name.to_s,
            "model" => effective_actor_value(
              context, routing, launch_cfg, :model, "provider-default"
            ),
            "effort" => effective_actor_value(
              context, routing, launch_cfg, :effort, "default"
            )
          },
          output: parse_role_output!(result[:final_message], role)
        }
      end

      def cleanup_producer_process_group(result)
        pgid = Integer(result&.fetch(:pgid, nil), exception: false)
        return unless pgid&.positive?

        Process.kill("TERM", -pgid)
        sleep 0.1
        Process.kill("KILL", -pgid)
      rescue Errno::ESRCH
        nil
      end

      def effective_actor_value(context, routing, actor_cfg, field, fallback)
        value = if context&.explicit_routing?
          context.public_send(field)
        else
          routing&.public_send(field) || actor_cfg[field.to_s]
        end
        value = value.to_s
        value.empty? ? fallback : value
      end

      def role_security_kwargs(role, task:, cfg:, profile:, actor_cfg:,
                               writable_root: nil, producer_runtime_policy: nil)
        if role == "producer"
          unless writable_root
            raise Hive::ConfigError,
                  "outcome-evidence producer requires a controller-scoped evidence-write root"
          end
          if profile.workspace_write_supported?
            return { permission_mode: Hive::AgentProfile::WORKSPACE_WRITE_PERMISSION_MODE }
          end
          if profile.name == :pi && producer_runtime_policy
            return Hive::Stages::Base.tool_scope_kwargs(
              permission_mode: producer_runtime_policy.permission_mode,
              allowed_tools: producer_runtime_policy.allowed_tools,
              disallowed_tools: producer_runtime_policy.disallowed_tools,
              runtime_policy: producer_runtime_policy
            )
          end
          unless profile.name == :claude
            raise Hive::ConfigError,
                  "outcome-evidence producer agent #{profile.name.inspect} cannot enforce " \
                  "controller-scoped evidence writes"
          end
          evidence_glob = File.join(File.expand_path(writable_root), "**")
          scope = Hive::Stages::Base.stage_permission_scope(
            cfg, "artifacts.evidence.producer", task, profile,
            base_add_dirs: [ task.folder, task.worktree_path ].compact,
            explicit_permission_spec: {
              "preset" => "scoped",
              "tools" => [ "Read", "LS", "Grep", "Glob", "Edit(#{evidence_glob})" ]
            }
          )
          return Hive::Stages::Base.tool_scope_kwargs(scope)
        end

        spec = actor_cfg.fetch("permissions", "read-only")
        if role != "producer" && spec.to_s != "read-only" &&
           !(spec.is_a?(Hash) && spec["preset"].to_s == "read-only")
          raise Hive::ConfigError, "artifacts.evidence.#{role} permissions cannot exceed read-only"
        end
        if role != "producer" && profile.name != :claude
          if profile.read_only_supported?
            return { permission_mode: Hive::AgentProfile::READ_ONLY_PERMISSION_MODE }
          end

          require "hive/workflow_package/runtime_policy"
          source_root = task.worktree_path || task.project_root
          runtime_policy = Hive::WorkflowPackage::RuntimePolicy.compile_actor(
            spec,
            task_folder: source_root,
            package_root: task.folder,
            profile: profile
          )
          return Hive::Stages::Base.tool_scope_kwargs(
            permission_mode: runtime_policy.permission_mode,
            allowed_tools: runtime_policy.allowed_tools,
            disallowed_tools: runtime_policy.disallowed_tools,
            runtime_policy: runtime_policy
          )
        end

        scope = Hive::Stages::Base.stage_permission_scope(
          cfg, "artifacts.evidence.#{role}", task, profile,
          base_add_dirs: [ task.folder, task.worktree_path ].compact,
          explicit_permission_spec: spec
        )
        Hive::Stages::Base.tool_scope_kwargs(scope)
      end

      def preflight_reviewer!(cfg, claims)
        capabilities = reviewer_capabilities(cfg)
        kinds = Array(capabilities["proof_kinds"]).map(&:to_s)
        required = Array(claims).map { |claim| claim.fetch("proof_kind") }.uniq
        missing = required - kinds
        unless missing.empty?
          raise Hive::ConfigError, "artifacts evidence reviewer lacks proof kinds: #{missing.join(', ')}"
        end
        if required.include?("video") && capabilities["temporal_video"] != true
          raise Hive::ConfigError,
                "artifacts evidence review must support retained temporal video and " \
                "controller-derived ordered frames"
        end
        true
      end

      def reviewer_capabilities(cfg)
        evidence_role_config(cfg, "reviewer").fetch(
          "capabilities", DEFAULT_REVIEW_CAPABILITIES
        )
      end

      def preflight_producer!(cfg, claims)
        actor_cfg = evidence_role_config(cfg, "producer")
        profile = Hive::Stages::Base.stage_profile(
          cfg, "artifacts", explicit_agent: actor_cfg["agent"] || cfg.dig("artifacts", "agent")
        )
        required = Array(claims).map { |claim| claim.fetch("proof_kind") }.uniq
        unsupported = required - [ "document" ]
        if unsupported.any? && !%i[codex pi].include?(profile.name)
          raise Hive::ConfigError,
                "artifacts evidence producer #{profile.name.inspect} cannot use the managed " \
                "agent-browser capture boundary; configure a Codex or Pi producer"
        end
        if unsupported.any? && profile.name == :codex &&
           (!profile.workspace_write_supported? || !profile.add_dir_flag)
          raise Hive::ConfigError,
                "artifacts evidence producer #{profile.name.inspect} cannot safely produce " \
                "#{unsupported.join(', ')} proof; configure a workspace-sandboxed producer " \
                "with per-attempt writable roots"
        end
        profile
      end

      def semantic_review_status!(verdicts)
        values = Array(verdicts).map { |verdict| verdict.fetch("verdict").to_s }
        unless values.any? && (values - %w[accepted revise blocked]).empty?
          raise Hive::Artifacts::OutcomeEvidence::StoreError,
                "semantic reviewer returned an unknown or empty verdict set"
        end
        return "blocked" if values.include?("blocked")
        return "revise" if values.include?("revise")

        "accepted"
      end

      def revision_guidance(requirement, prior)
        return [] unless prior

        claim_ids = requirement.fetch("claims").map { |claim| claim.fetch("id") }
        prior.dig("review", "verdicts").to_a.filter_map do |verdict|
          next unless verdict.fetch("verdict") == "revise"
          next unless claim_ids.include?(verdict.fetch("target_id"))

          verdict.slice("target_id", "reason")
        end
      end

      def unrecapturable_revision?(requirement, prior)
        claim_ids = requirement.fetch("claims").map { |claim| claim.fetch("id") }
        prior.dig("review", "verdicts").to_a.any? do |verdict|
          verdict.fetch("verdict") == "revise" &&
            !claim_ids.include?(verdict.fetch("target_id"))
        end
      end

      def merge_candidate_evidence!(prior, replacements, revision)
        return replacements unless prior

        target_ids = Array(revision).map { |item| item.fetch("target_id") }
        replacement_claims = Array(replacements).flat_map do |entry|
          Array(entry.fetch("claims"))
        end.uniq
        unless replacement_claims.any? &&
               (replacement_claims - target_ids).empty?
          raise Hive::Artifacts::OutcomeEvidence::StoreError,
                "targeted recapture may replace only claims requested for revision"
        end

        preserved = Array(prior.fetch("evidence")).filter_map do |entry|
          copy = JSON.parse(JSON.generate(entry))
          copy["claims"] = Array(copy.fetch("claims")) - replacement_claims
          copy unless copy.fetch("claims").empty?
        end
        preserved + replacements
      end

      def block_from_review!(task, store, requirement, history, attempt,
                             reason: "review_blocked")
        verdicts = attempt.dig("review", "verdicts").to_a
        failed = verdicts.reject { |verdict| verdict.fetch("verdict") == "accepted" }
        pointer = store.publish_blocked!(
          generation: requirement.fetch("generation"), reason: reason,
          failed_targets: failed.map { |verdict| verdict.fetch("target_id") },
          reviewer_reasons: failed.map { |verdict| verdict.fetch("reason") },
          attempt_ids: history.map { |item| item.fetch("attempt_id") }
        )
        publish_blocked_marker!(task, pointer)
        { commit: "error", status: :error }
      end

      def evidence_role_config(cfg, role)
        value = cfg.dig("artifacts", "evidence", role)
        value.is_a?(Hash) ? value : {}
      end

      def evidence_role_launch_config(cfg, actor_cfg)
        launch = actor_cfg.slice("model", "effort")
        stage_agent = cfg.dig("artifacts", "agent")
        role_agent = actor_cfg["agent"]
        if role_agent.nil? || role_agent.to_s == stage_agent.to_s
          launch["model"] ||= cfg.dig("artifacts", "model")
          launch["effort"] ||= cfg.dig("artifacts", "effort")
        end
        launch
      end

      def parse_role_output!(source, role)
        text = source.to_s
        if text.empty? || text.bytesize > Hive::Artifacts::OutcomeEvidence::Store::MAX_DOCUMENT_BYTES
          raise RoleOutputError, "#{role} output is missing or oversized"
        end
        value = JSON.parse(
          text, object_class: Hive::Artifacts::OutcomeEvidence::Document::StrictHash,
          allow_duplicate_key: false
        )
        raise RoleOutputError, "#{role} output must be one exact JSON object" unless value.is_a?(Hash)
        value
      rescue JSON::ParserError => e
        raise RoleOutputError, "#{role} output is invalid JSON: #{e.message}"
      end

      def ensure_producer_paths!(task, writable_root, evidence)
        relative_root = Pathname.new(writable_root).relative_path_from(Pathname.new(task.folder)).to_s
        prefix = "#{relative_root}/"
        Array(evidence).each do |entry|
          next if entry.dig("source", "type").to_s == "project_provider"

          Array(entry["representations"]).each do |representation|
            path = Hive::Artifacts::OutcomeEvidence::Identity.validate_changed_path!(representation.fetch("path"))
            unless path.start_with?(prefix)
              raise Hive::Artifacts::OutcomeEvidence::StoreError,
                    "producer evidence must remain under its controller-owned writable root"
            end
          end
        end
      end

      def representation_hashes(evidence)
        Array(evidence).flat_map do |entry|
          Array(entry.fetch("representations")).filter_map do |row|
            row["sha256"]&.to_s&.downcase
          end
        end.uniq.sort
      end

      def remove_producer_work!(task, writable_root)
        work_root = File.join(task.folder, "outcome-evidence", "work")
        path = File.expand_path(writable_root)
        prefix = "#{File.expand_path(work_root)}#{File::SEPARATOR}"
        unless path.start_with?(prefix)
          raise Hive::Artifacts::OutcomeEvidence::StoreError,
                "producer cleanup root escapes controller-owned work storage"
        end

        stat = File.lstat(path)
        if stat.symlink? || !stat.directory?
          File.unlink(path)
        else
          FileUtils.remove_entry_secure(path)
        end
      rescue Errno::ENOENT
        nil
      end

      def role_firewall_manifest(task, writable_root)
        protected = (
          Hive::ArtifactFirewall::ORCHESTRATOR_OWNED +
          %w[artifact.md capture-requirement.json pr.md]
        ).uniq
        Hive::ArtifactFirewall::Manifest.new(
          root: task.folder, protected_anchors: protected,
          permitted_writable_roots: [ writable_root || task.folder ].compact,
          required_outputs: {}
        )
      end

      def render_role_prompt(template, task, **values)
        Hive::Stages::Base.render(
          template,
          Hive::Stages::Base::TemplateBindings.new(
            {
              task_folder: task.folder, worktree_path: task.worktree_path,
              artifact_file: task.state_file,
              user_supplied_tag: Hive::Stages::Base.user_supplied_tag
            }.merge(values)
          )
        )
      end

      def publish_complete_marker!(task, pointer)
        source = <<~MARKDOWN
          Outcome evidence generation: #{pointer.fetch("generation")}
          Accepted attempt: #{pointer.fetch("attempt_id")}

          <!-- COMPLETE -->
        MARKDOWN
        Hive::AtomicFile.write(task.state_file, source, mode: 0o600)
      end

      def publish_blocked_marker!(task, pointer)
        reason = "outcome_evidence_#{pointer.fetch('reason')}"
        Hive::Markers.set(
          task.state_file, :error,
          reason: reason,
          generation: pointer.fetch("generation"),
          recovery_digest: pointer.fetch("recovery_digest"),
          attempt_count: pointer.fetch("attempt_count"),
          failed_targets: pointer.fetch("failed_targets").join(",")
        )
      end

      def run_legacy_capture!(task, cfg)
        capture_policy = Hive::Artifacts::CapturePolicy.for_task(
          task,
          project: File.basename(task.project_root)
        )
        capture_requirement = capture_policy.ensure!
        marker = Hive::Markers.current(task.state_file)
        if marker.name == :complete
          return { commit: nil, status: :complete } if capture_policy.capture_satisfied?

          return required_capture_error(task, capture_requirement)
        end

        profile = Hive::Stages::Base.stage_profile(cfg, "artifacts")
        # External upload is deliberately outside the stage. Do not read or
        # inject the operator's Screenote credential during autonomous capture.
        screenote = build_unavailable_context(
          "External upload requires a separate operator-confirmed action after local inspection.",
          cfg
        )
        prompt = render_prompt(
          task,
          screenote: screenote,
          capture_requirement: capture_requirement
        )
        spawn_artifacts_agent(task, cfg, prompt, profile, screenote: screenote)
        marker = Hive::Markers.current(task.state_file)
        if marker.name == :complete && !capture_policy.capture_satisfied?
          return required_capture_error(task, capture_requirement)
        end
        { commit: action_for(marker.name), status: marker.name }
      end

      def required_capture_error(task, requirement)
        Hive::Markers.set(
          task.state_file,
          :error,
          reason: "required_capture_missing",
          capture_requirement: requirement.fetch("result"),
          remediation: "run supervised local capture and retain media/capture-manifest.json"
        )
        { commit: "error", status: :error }
      end

      # `screenote:` is required (no `screenote_context(cfg)` default): the
      # default ran a real CredentialStore.new.load against the dev machine for
      # any caller that omitted it, coupling tests to ambient disk state. The
      # sole production caller (run!) always passes it.
      def spawn_artifacts_agent(task, cfg, prompt, profile, screenote:)
        cwd = File.directory?(task.worktree_path.to_s) ? task.worktree_path : task.folder
        scope = Hive::Stages::Base.stage_permission_scope_or_mark!(
          cfg, "artifacts", task, profile,
          default_allowed_tools: Hive::ClaudeLauncher::IMPLEMENTER_ALLOWED_TOOLS
        )
        kwargs = {
          prompt: prompt,
          add_dirs: scope.fetch(:add_dirs),
          cwd: cwd,
          max_budget_usd: cfg.dig("budget_usd", "artifacts") || Hive::Config::DEFAULTS.dig("budget_usd", "artifacts"),
          timeout_sec: cfg.dig("timeout_sec", "artifacts") || Hive::Config::DEFAULTS.dig("timeout_sec", "artifacts"),
          log_label: "artifacts",
          profile: profile,
          **Hive::Stages::Base.model_launch_arguments(
            cfg, "artifacts", profile,
            current: Hive::Stages::Base.model_routing_current(cfg["artifacts"])
          ),
          **Hive::Stages::Base.tool_scope_kwargs(scope),
          status_mode: :state_file_marker
        }
        mcp_config_path = nil
        if profile.name == :claude
          allowed_tools = Hive::ClaudeLauncher::IMPLEMENTER_ALLOWED_TOOLS
          if screenote[:connected]
            begin
              mcp_config_path = Hive::Screenote::McpConfig.new(credential: screenote.fetch(:credential)).write!
              allowed_tools = Hive::Screenote::McpConfig.allowed_tools_csv(allowed_tools)
            rescue SystemCallError, Hive::ConfigError => e
              # An unwritable/full cache_home (SystemCallError) OR a credential
              # that lost a required key between screenote_context's check and
              # McpConfig#payload (Hive::ConfigError) must degrade to a no-MCP
              # run (the agent keeps local media), not hard-fail the stage (A8).
              warn "[hive] could not write Screenote MCP config; running artifacts " \
                   "without Screenote upload: #{e.message}"
              mcp_config_path = nil
            end
          end
          Hive::Stages::Base.spawn_claude_with_tmux_marker!(
            task,
            cfg,
            **kwargs,
            session_name: Hive::ClaudeLauncher.tmux_session_name("7-artifacts", task), # coding-scoped: coding artifacts stage tmux session
            allowed_tools: allowed_tools,
            mcp_config_path: mcp_config_path,
            strict_mcp_config: !mcp_config_path.nil?
          )
        else
          Hive::Stages::Base.spawn_agent(task, **kwargs)
        end
      ensure
        if mcp_config_path
          begin
            FileUtils.rm_f(mcp_config_path)
          rescue SystemCallError => e
            # The ephemeral 0600 config embeds the bearer; if cleanup fails
            # (e.g. EACCES) it lingers on disk. Surface it so an operator can
            # remove it, rather than swallowing the failure silently.
            warn "[hive] could not remove ephemeral Screenote MCP config #{mcp_config_path}: #{e.message}"
          end
        end
      end

      def render_prompt(task, screenote: nil, capture_requirement: nil)
        screenote ||= build_unavailable_context("Screenote is not connected; run `hive connect screenote`.", {})
        capture_requirement ||= {
          "result" => "not_applicable",
          "rationale" => "No precomputed capture requirement was supplied.",
          "task_generation" => "unknown"
        }
        Hive::Stages::Base.render(
          "artifacts_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(task.project_root),
            task_folder: task.folder,
            worktree_path: task.worktree_path,
            artifact_file: task.state_file,
            capture_requirement: capture_requirement.fetch("result"),
            capture_rationale: capture_requirement.fetch("rationale"),
            capture_generation: capture_requirement.fetch("task_generation"),
            screenote_connected: screenote[:connected],
            screenote_project_id: screenote[:project_id],
            screenote_base_url: screenote[:base_url],
            screenote_skip_reason: screenote[:reason],
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
      end

      def screenote_context(cfg, credential_store: Hive::Screenote::CredentialStore.new, now: Time.now)
        credential = credential_store.load
        return warn_and_build_unavailable("Screenote is not connected; run `hive connect screenote`.", cfg) unless credential

        if credential_store.expired?(credential, now: now)
          return warn_and_build_unavailable("Screenote OAuth token expired; run `hive connect screenote`.", cfg)
        end

        project_id = cfg.dig("screenote", "project_id").to_s.strip
        project_id = credential["project_id"].to_s.strip if project_id.empty?
        if project_id.empty?
          return warn_and_build_unavailable("Screenote has no default project; run `hive connect screenote`.", cfg)
        end

        if credential["access_token"].to_s.strip.empty? || credential["mcp_resource"].to_s.strip.empty?
          return warn_and_build_unavailable("Screenote credential is incomplete; run `hive connect screenote`.", cfg)
        end

        {
          connected: true,
          credential: credential,
          project_id: project_id,
          base_url: connected_base_url(credential, cfg),
          reason: nil
        }
      rescue Hive::ConfigError => e
        warn_and_build_unavailable("Screenote credential is invalid: #{e.message}", cfg)
      rescue SystemCallError => e
        # A8 fail-soft: a read failure on the credential file (EACCES /
        # EISDIR / a TOCTOU ENOENT) must skip Screenote, not hard-fail the
        # 7-artifacts stage. CredentialStore#load only rescues JSON errors,
        # so an OS-level File.read failure escapes here as SystemCallError.
        warn_and_build_unavailable("Screenote credential could not be read: #{e.message}", cfg)
      end

      # Visible fail-soft: warn at run time so an operator watching the run
      # sees WHY no upload happened (the cause was otherwise buried only in
      # the prompt/manifest), then return the unavailable context. Used by
      # screenote_context's skip paths; `build_unavailable_context` stays the
      # silent builder for render_prompt's default binding (which deliberately
      # skips the warn).
      def warn_and_build_unavailable(reason, cfg)
        warn "[hive] Screenote upload disabled for artifacts: #{reason}"
        build_unavailable_context(reason, cfg)
      end

      def build_unavailable_context(reason, cfg)
        {
          connected: false,
          credential: nil,
          project_id: nil,
          base_url: config_base_url(cfg),
          reason: reason
        }
      end

      # The configured Screenote base URL, falling back to the OAuth
      # client's default. The `|| DEFAULT_BASE_URL` fallback is load-bearing
      # for `render_prompt`'s empty-cfg default-arg path.
      def config_base_url(cfg)
        cfg.dig("screenote", "base_url") || Hive::Screenote::OAuthClient::DEFAULT_BASE_URL
      end

      def connected_base_url(credential, cfg)
        credential["base_url"].to_s.empty? ? config_base_url(cfg) : credential["base_url"]
      end

      def action_for(marker_name)
        case marker_name
        when :complete then "artifacts_collected"
        when :error then "error"
        else marker_name.to_s
        end
      end
    end
  end
end
