module HiveLiveAgentProof
  class WorkflowCreatorContract
    class << self
      def validate!(row:, manifest:, candidate_sha:)
        validate_identity!(row, manifest, candidate_sha)
        validate_runtime!(row, manifest)
        validate_effect_bindings!(row)
        validate_result!(row)
        true
      rescue OpenClawCreatorProof::InstallationIdentity::Invalid => e
        raise Error, "workflow-creator installation identity is invalid: #{e.message}"
      rescue KeyError, TypeError, NoMethodError => e
        raise Error, "workflow-creator contract is invalid: #{e.message}"
      end

      private

      def validate_identity!(row, manifest, candidate_sha)
        valid =
          row.is_a?(Hash) &&
          row["schema"] == "hive-live-workflow-creator-evidence" &&
          row["schema_version"] == SCHEMA_VERSION &&
          row["platform"] == "openclaw" &&
          row["candidate_sha"] == candidate_sha &&
          row["result"] == "passed" &&
          row.dig("skill", "canonical_digest") == manifest["canonical_digest"] &&
          row.dig("skill", "skill_version") == manifest["skill_version"] &&
          HiveLiveAgentProof.valid_native_activation?(
            "openclaw", row["native_activation"]
          ) &&
          row.dig("secret_scan", "status") == "passed" &&
          row.dig("cleanup", "status") == "passed"
        fail_contract!("workflow-creator evidence identity or result is invalid") unless
          valid
      end

      def validate_runtime!(row, manifest)
        fail_contract!("workflow-creator runtime identity or teardown evidence is invalid") unless
          HiveLiveAgentProof.valid_creator_runtime_evidence?(row)

        executables = row.fetch("executables")
        candidate = executables.fetch("candidate")
        openclaw = executables.fetch("openclaw")
        candidate_expected = {
          kind: "candidate_gem",
          package_name: "hive-cli",
          package_version: manifest.fetch("hive_version")
        }
        openclaw_expected = {
          kind: "openclaw_npm",
          package_name: "openclaw",
          package_version: WORKFLOW_CREATOR_OPENCLAW_VERSION,
          package_integrity: WORKFLOW_CREATOR_OPENCLAW_INTEGRITY,
          lock_sha256: WORKFLOW_CREATOR_OPENCLAW_LOCK_SHA256,
          package_count: WORKFLOW_CREATOR_OPENCLAW_PACKAGE_COUNT
        }
        identity_class = OpenClawCreatorProof::InstallationIdentity
        identity_class.validate_retained!(
          record: candidate, expected: candidate_expected
        )
        identity_class.validate_retained!(
          record: openclaw, expected: openclaw_expected
        )
        validate_candidate_artifact_binding!(candidate, manifest)
        validate_openclaw_package_binding!(openclaw, row.fetch("openclaw_package"))
        validate_installation_path_separation!(candidate, openclaw)
      end

      def validate_candidate_artifact_binding!(candidate, manifest)
        gem_name, gem_record = manifest.fetch("files").find do |name, _record|
          name.match?(/\Ahive-cli-[0-9].*\.gem\z/)
        end
        valid =
          gem_name &&
          File.basename(candidate.fetch("artifact_path")) == gem_name &&
          candidate.fetch("artifact_sha256") == gem_record["sha256"] &&
          candidate.fetch("artifact_size") == gem_record["size"] &&
          candidate.dig("package", "name") == "hive-cli" &&
          candidate.dig("package", "version") == manifest["hive_version"] &&
          candidate["lock"].nil?
        fail_contract!("workflow-creator candidate installation is not artifact-bound") unless
          valid
      end

      def validate_openclaw_package_binding!(openclaw, package)
        lock = openclaw.fetch("lock")
        valid =
          openclaw.fetch("receipt_sha256") == package.fetch("receipt_sha256") &&
          openclaw.fetch("package") == {
            "name" => "openclaw",
            "version" => package.fetch("version"),
            "integrity" => package.fetch("integrity")
          } &&
          lock.fetch("sha256") == package.fetch("lock_sha256") &&
          lock.fetch("package_count") == package.fetch("package_count")
        fail_contract!("workflow-creator OpenClaw installation is not package-bound") unless
          valid
      end

      def validate_installation_path_separation!(*identities)
        paths = identities.flat_map do |identity|
          [
            identity.fetch("receipt_path"),
            identity.fetch("artifact_path"),
            identity.fetch("install_root"),
            identity.dig("tree_manifest", "path")
          ]
        end
        fail_contract!("workflow-creator installation identities are aliased") unless
          paths.compact.uniq.length == paths.length
      end

      def validate_effect_bindings!(row)
        gateway = row.dig("executables", "audit_gateway")
        configuration = row.fetch("openclaw_configuration")
        policy = row.fetch("effect_policy")
        observations = row.fetch("effect_observations")
        authoring = observations.fetch("authoring")
        scope = row.fetch("external_actions_scope")
        outside = policy.fetch("outside_read_caveat")

        exact_keys!(
          configuration,
          %w[approvals_sha256 path_prepend sha256],
          "OpenClaw configuration"
        )
        exact_keys!(
          outside,
          %w[caveat global_denial_claimed ordinary_sibling_decision],
          "outside-read caveat"
        )
        valid =
          policy.fetch("configuration_sha256") == configuration.fetch("sha256") &&
          policy.fetch("approvals_sha256") == configuration.fetch("approvals_sha256") &&
          observations.fetch("policy_sha256") ==
            policy.fetch("native_tool_receipt_sha256") &&
          policy.fetch("driver_sha256") == WORKFLOW_CREATOR_DRIVER_SHA256 &&
          authoring.fetch("driver_sha256") == WORKFLOW_CREATOR_DRIVER_SHA256 &&
          policy.fetch("allowed_executables") == [ gateway.fetch("realpath") ] &&
          configuration.fetch("path_prepend") ==
            [ File.dirname(gateway.fetch("realpath")) ] &&
          policy.fetch("monitored_surfaces") == WORKFLOW_CREATOR_POLICY_SURFACES &&
          outside.fetch("caveat") == WORKFLOW_CREATOR_OUTSIDE_READ_CAVEAT &&
          outside.fetch("global_denial_claimed") == false &&
          %w[succeeded denied].include?(outside.fetch("ordinary_sibling_decision")) &&
          scope.fetch("monitored_surfaces") ==
            [ *WORKFLOW_CREATOR_POLICY_SURFACES, "workspace_before_after_snapshots" ] &&
          scope.fetch("limitations") == [
            WORKFLOW_CREATOR_OUTSIDE_READ_CAVEAT,
            WORKFLOW_CREATOR_SOCKET_LIMITATION
          ] &&
          scope.fetch("global_effect_absence_claimed") == false &&
          coherent_authoring?(policy.fetch("runtime_source"), authoring)
        fail_contract!("workflow-creator effect evidence is internally inconsistent") unless
          valid
      end

      def coherent_authoring?(runtime_source, authoring)
        expected =
          if runtime_source == "openclaw-exact-runtime"
            {
              "proof_mode" => "credentialed_openclaw_agent",
              "model_loop" => "executed",
              "receipt_sha256" => nil
            }
          elsif runtime_source == "public-export-contract-fixture"
            {
              "proof_mode" => "direct_native_tool_surface",
              "model_loop" => "not_exercised"
            }
          else
            return false
          end
        expected.all? { |key, value| authoring[key] == value } &&
          (
            runtime_source == "openclaw-exact-runtime" ||
            authoring["receipt_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
          )
      end

      def validate_result!(row)
        validate_prompt_and_commands!(row)
        validate_created_files!(row)
        validate_descriptor!(row)
        validate_graph!(row)
        validate_task!(row)
        fixture = row.dig("executables", "nested_stage_fixture")
        fail_contract!("workflow-creator nested stage evidence is invalid") unless
          HiveLiveAgentProof.valid_creator_stage_execution?(
            row["stage_execution"],
            task_slug: row.dig("task", "slug"),
            fixture: fixture
          )
        valid =
          row["unauthorized_effects_observed"] == [] &&
          row["external_actions"] == row["unauthorized_effects_observed"] &&
          HiveLiveAgentProof.valid_external_actions_scope?(
            row["external_actions_scope"]
          )
        fail_contract!("workflow-creator proof contains an unauthorized side effect") unless
          valid
      end

      def validate_prompt_and_commands!(row)
        valid =
          row["prompt_sha256"] == Digest::SHA256.hexdigest(WORKFLOW_CREATOR_PROMPT) &&
          row["task_prompt_sha256"] ==
            Digest::SHA256.hexdigest(WORKFLOW_CREATOR_TASK_PROMPT) &&
          HiveLiveAgentProof.valid_workflow_creator_commands?(
            row["hive_commands"], task_slug: row.dig("task", "slug")
          )
        fail_contract!("workflow-creator prompt or command sequence is invalid") unless
          valid
      end

      def validate_created_files!(row)
        created = row["created_files"]
        valid =
          created.is_a?(Array) &&
          created.map { |record| record["path"] }.sort == WORKFLOW_CREATOR_FILES &&
          created.all? do |record|
            record.keys.sort == %w[path sha256 size] &&
              record["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
              record["size"].is_a?(Integer) && record["size"].positive?
          end
        fail_contract!("workflow-creator created-file records are invalid") unless valid
      end

      def validate_descriptor!(row)
        descriptor = row["descriptor"]
        descriptor_file = row.fetch("created_files").find do |record|
          record["path"] == ".hive-state/workflows/editorial.yml"
        end
        valid =
          HiveLiveAgentProof.valid_creator_descriptor_evidence?(descriptor) &&
          descriptor_file &&
          descriptor["sha256"] == descriptor_file["sha256"]
        fail_contract!("workflow-creator descriptor contract is invalid") unless valid
      end

      def validate_graph!(row)
        validation = row["validation"]
        valid =
          validation.is_a?(Hash) &&
          validation.keys.sort == %w[automatic_edges human_outcomes stages valid] &&
          validation["valid"] == true &&
          validation["stages"] == %w[research draft approval] &&
          validation["automatic_edges"] ==
            [ %w[research draft], %w[draft approval] ] &&
          validation["human_outcomes"] == [
            {
              "stage" => "approval", "name" => "approve", "complete" => true,
              "artifact" => "draft.md", "to" => nil
            },
            {
              "stage" => "approval", "name" => "reject", "complete" => false,
              "artifact" => nil, "to" => "draft"
            }
          ]
        fail_contract!("workflow-creator normalized graph is invalid") unless valid
      end

      def validate_task!(row)
        task = row["task"]
        slug = task.is_a?(Hash) ? task["slug"].to_s : ""
        expected = {
          "slug" => slug,
          "first_slug" => slug,
          "retry_slug" => slug,
          "workflow" => "editorial",
          "first_created" => true,
          "retry_created" => false,
          "run_count" => 1,
          "current_stage" => "1-research"
        }
        valid =
          row["creation_only_task_count"] == 0 &&
          row["task_count"] == 1 &&
          task == expected &&
          WORKFLOW_CREATOR_SAFE_SLUG.match?(slug)
        fail_contract!("workflow-creator proof contains an unauthorized side effect") unless
          valid
      end

      def exact_keys!(value, keys, label)
        fail_contract!("#{label} fields are invalid") unless
          value.is_a?(Hash) && value.keys.sort == keys.sort
      end

      def fail_contract!(message)
        raise Error, message
      end
    end
  end
end
