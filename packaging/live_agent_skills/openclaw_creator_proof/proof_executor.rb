module HiveLiveAgentProof
  module OpenClawCreatorProof
    class ProofExecutor
      AGENT_TIMEOUT = 240

      def initialize(root:, candidate:, openclaw:, git:, candidate_sha:, artifact_dir:,
                     model:, environment_policy:, document:, process_runner:)
        @root = root
        @candidate = candidate
        @openclaw = openclaw
        @git = git
        @candidate_sha = candidate_sha
        @artifact_dir = artifact_dir
        @model = model
        @environment_policy = environment_policy
        @document = document
        @process_runner = process_runner
      end

      def call
        verified, materialized_root = verify_and_materialize_candidate
        sandbox = prepare_project
        installer = install_workspace(sandbox, verified, materialized_root)
        gateway, gateway_path, audit_path = install_gateway(sandbox)
        configuration = configure_openclaw(sandbox, gateway_path)
        environment = proof_environment(sandbox, configuration, installer.codex_path)
        inspector = ProofInspector.new(
          workspace: sandbox.workspace,
          audit_path: audit_path,
          result_path: gateway.result_path,
          candidate_record: @candidate,
          configuration: configuration
        )

        verify_openclaw_version(environment, sandbox)
        discovery = verify_skill_discovery(environment, sandbox, installer)
        run_agent(sandbox, environment, WORKFLOW_CREATOR_PROMPT, "workflow_creation")
        creation = inspector.creation_result
        run_agent(sandbox, environment, WORKFLOW_CREATOR_TASK_PROMPT, "task_creation")
        task = inspector.final_result
        record_success(installer, discovery, creation, task)
      rescue JSON::ParserError, KeyError, Errno::ENOENT, Errno::EACCES => e
        fail_with!(@document.data["phase"], "proof_data_invalid", e.message)
      end

      private

      def verify_and_materialize_candidate
        @document.phase = "artifact_verification"
        canonical = Hive::AgentSkills::CanonicalSkill.new
        verified = CandidateVerifier.new(
          candidate_dir: @artifact_dir,
          candidate_sha: @candidate_sha,
          expected_hive_version: Hive::VERSION,
          canonical: canonical
        ).call
        verify_candidate_installation!(verified.fetch("gem"))
        materialized_root = File.join(@root, "materialized-skills")
        records = SafeTarMaterializer.new(
          archive: verified.fetch("skills"),
          destination: materialized_root
        ).call
        @document.merge!("candidate_artifacts" => {
          "manifest_sha256" =>
            Digest::SHA256.file(File.join(@artifact_dir, "artifact-manifest.json")).hexdigest,
          "materialized_file_count" => records.length
        })
        [ verified, materialized_root ]
      rescue HiveLiveAgentProof::Error, Hive::AgentSkills::ValidationError => e
        fail_with!("artifact_verification", "candidate_artifacts_invalid", e.message)
      end

      def verify_candidate_installation!(verified_gem)
        artifact_path = File.realpath(verified_gem)
        artifact_digest = Digest::SHA256.file(artifact_path).hexdigest
        return if @candidate.fetch("artifact_path") == artifact_path &&
                  @candidate.fetch("artifact_sha256") == artifact_digest

        fail_with!(
          "artifact_verification",
          "candidate_installation_receipt_mismatch",
          "candidate installation receipt is not bound to the verified candidate gem"
        )
      end

      def prepare_project
        @document.phase = "project_setup"
        ProjectSandbox.new(
          root: @root,
          candidate_path: @candidate.fetch("realpath"),
          git_path: @git.fetch("realpath"),
          process_runner: @process_runner,
          environment: @environment_policy.sanitized_environment,
          document: @document
        ).prepare
      end

      def install_workspace(sandbox, verified, materialized_root)
        installer = WorkspaceInstaller.new(workspace: sandbox.workspace, root: @root)
        installer.install_skill(
          materialized_root: materialized_root,
          manifest: verified.fetch("manifest")
        )
        installer.install_codex_fixture
        installer
      end

      def install_gateway(sandbox)
        audit_path = File.join(@root, "audit", "hive-argv.jsonl")
        gateway = AuditGateway.new(
          candidate_path: @candidate.fetch("realpath"),
          directory: File.join(@root, "audit-gateway"),
          audit_path: audit_path,
          workspace: sandbox.workspace
        )
        gateway_path = gateway.install
        bound = %w[configured_path realpath sha256].all? do |key|
          gateway.candidate_record.fetch(key) == @candidate.fetch(key)
        end
        unless bound &&
               gateway.gateway_record.fetch("realpath") != @candidate.fetch("realpath")
          fail_with!(
            "gateway", "gateway_identity_invalid",
            "candidate and audit gateway identities are not distinct and bound"
          )
        end
        @document.set_executable("audit_gateway", gateway.gateway_record)
        [ gateway, gateway_path, audit_path ]
      end

      def configure_openclaw(sandbox, gateway_path)
        configuration = OpenClawConfiguration.new(
          root: @root,
          workspace: sandbox.workspace,
          model: @model,
          gateway_bin_dir: File.dirname(gateway_path)
        )
        config = configuration.write
        @document.merge!("openclaw_configuration" => {
          "sha256" => Digest::SHA256.file(configuration.config_path).hexdigest,
          "approvals_sha256" =>
            Digest::SHA256.file(configuration.approvals_path).hexdigest,
          "path_prepend" => config.dig("tools", "exec", "pathPrepend")
        })
        configuration
      end

      def proof_environment(sandbox, configuration, codex_path)
        @environment_policy.child_environment(
          "HOME" => sandbox.home,
          "HIVE_HOME" => sandbox.hive_home,
          "OPENCLAW_STATE_DIR" => configuration.state_dir,
          "OPENCLAW_CONFIG_PATH" => configuration.config_path,
          "HIVE_CODEX_BIN" => codex_path,
          "HIVE_LIVE_PROOF" => "1",
          "HIVE_SKIP_LLM_WIKI_SCHEDULER" => "1",
          "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1",
          "HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "1"
        )
      end

      def verify_openclaw_version(environment, sandbox)
        result = run_proof(
          "openclaw_version", environment,
          [ @openclaw.fetch("realpath"), "--version" ],
          chdir: sandbox.workspace, timeout: 30
        )
        version = result.fetch("stdout").to_s.scrub.lines.first.to_s.strip
        pattern = /\AOpenClaw #{Regexp.escape(OPENCLAW_VERSION)} \(.+\)\z/
        unless pattern.match?(version)
          fail_with!(
            "discovery", "openclaw_version_mismatch",
            "expected decorated OpenClaw #{OPENCLAW_VERSION} identity, got #{version.inspect}"
          )
        end
        @document.data.fetch("executables").fetch("openclaw")["version"] = version
      end

      def verify_skill_discovery(environment, sandbox, installer)
        result = run_proof(
          "skill_discovery", environment,
          [ @openclaw.fetch("realpath"), "skills", "info", "hive", "--json" ],
          chdir: sandbox.workspace, timeout: 60
        )
        payload = JSON.parse(result.fetch("stdout"))
        expected_skill = File.realpath(File.join(installer.skill_root, "SKILL.md"))
        unless payload["name"] == "hive" && payload["eligible"] == true &&
               payload["userInvocable"] == true &&
               File.realpath(payload.fetch("filePath")) == expected_skill
          fail_with!(
            "discovery", "native_skill_discovery_failed",
            "OpenClaw did not discover the installed candidate Hive skill"
          )
        end
        payload
      end

      def run_agent(sandbox, environment, prompt, label)
        run_proof(
          label, environment,
          [
            @openclaw.fetch("realpath"), "agent", "--local", "--agent", "main",
            "--message", prompt, "--timeout", "180", "--json"
          ],
          chdir: sandbox.workspace,
          timeout: AGENT_TIMEOUT
        )
      end

      def run_proof(label, environment, argv, chdir:, timeout:)
        @document.phase = label
        result = @process_runner.call(
          environment: environment,
          argv: argv,
          chdir: chdir,
          timeout: timeout
        )
        @document.record_process(result, label: label)
        unless result.fetch("secret_findings").empty?
          fail_with!(
            label, "secret_material_detected",
            "raw process output contained credential material"
          )
        end
        return result if result.fetch("status")&.success? &&
                         result.dig("record", "timed_out") == false &&
                         result.dig("record", "interrupted") == false &&
                         result.dig("record", "teardown", "status") == "passed"

        detail = result.fetch("stderr").to_s.scrub.lines.first(12).join
        fail_with!(label, "#{label}_failed", detail.empty? ? "process failed" : detail)
      end

      def record_success(installer, discovery, creation, task)
        @document.merge!(
          "result" => "passed",
          "phase" => "complete",
          "reason" => "proof_passed",
          "prompt_sha256" => Digest::SHA256.hexdigest(WORKFLOW_CREATOR_PROMPT),
          "task_prompt_sha256" => Digest::SHA256.hexdigest(WORKFLOW_CREATOR_TASK_PROMPT),
          "agent" => {
            "binary" => "openclaw",
            "discovery_sha256" => Digest::SHA256.hexdigest(JSON.generate(discovery))
          },
          "skill" => {
            "skill_version" => installer.projection.fetch("skill_version"),
            "canonical_digest" => installer.projection.fetch("canonical_digest"),
            "projection_manifest_sha256" =>
              Digest::SHA256.file(File.join(installer.skill_root, ".hive-skill.json")).hexdigest
          },
          "native_activation" => {
            "kind" => NATIVE_ACTIVATION_KINDS.fetch("openclaw"),
            "invocation" => INVOCATIONS.fetch("openclaw")
          },
          "hive_commands" => task.fetch("hive_commands"),
          "created_files" => creation.fetch("created_files"),
          "validation" => creation.fetch("validation"),
          "creation_only_task_count" => creation.fetch("creation_only_task_count"),
          "task_count" => task.fetch("task_count"),
          "task" => task.fetch("task"),
          "effect_policy" => task.fetch("effect_policy"),
          "external_actions" => task.fetch("external_actions")
        )
        @document.data
      end

      def fail_with!(phase, reason, detail)
        raise Failure.new(phase: phase, reason: reason, detail: detail)
      end
    end
  end
end
