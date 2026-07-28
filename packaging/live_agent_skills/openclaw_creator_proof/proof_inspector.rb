module HiveLiveAgentProof
  module OpenClawCreatorProof
    class ProofInspector
      WORKFLOW_CONTROL_FILES = [ ".hive-state/workflows/.mutation.lock" ].freeze

      def initialize(workspace:, audit_path:, result_path:, candidate_record:,
                     configuration: nil, policy_path: nil, authoring_path: nil,
                     effects_path: nil, process_records: [])
        @workspace = File.expand_path(workspace)
        @audit_path = File.expand_path(audit_path)
        @result_path = File.expand_path(result_path)
        @candidate_record = candidate_record
        @configuration = configuration
        @policy_path = policy_path && File.expand_path(policy_path)
        @authoring_path = authoring_path && File.expand_path(authoring_path)
        @effects_path = effects_path && File.expand_path(effects_path)
        @process_records = process_records
      end

      def creation_result
        rows = audit_rows
        unless rows.length == 5 &&
               rows.map { |row| row.fetch("argv") } == WORKFLOW_CREATOR_COMMANDS.first(5)
          fail_proof!("creation agent did not execute the exact first five Hive commands")
        end
        {
          "hive_commands" => rows.map { |row| row.fetch("argv") },
          "created_files" => created_file_records,
          "validation" => validation_result,
          "creation_only_task_count" => task_folders.length
        }.tap do |result|
          fail_proof!("creation-only agent created a task") unless
            result.fetch("creation_only_task_count").zero?
        end
      end

      def final_result
        rows = audit_rows
        task_creations = result_rows.select { |row| row["kind"] == "task_creation" }
        unless task_creations.length == 2
          fail_proof!("gateway did not retain both task creation results")
        end
        first = task_creations.fetch(0)
        retry_result = task_creations.fetch(1)
        slug = first.fetch("slug").to_s
        unless first["created"] == true && retry_result["created"] == false &&
               retry_result["slug"] == slug && WORKFLOW_CREATOR_SAFE_SLUG.match?(slug)
          fail_proof!("idempotent creation results did not bind one safe slug")
        end
        expected_commands = HiveLiveAgentProof.workflow_creator_commands(slug)
        unless rows.length == expected_commands.length &&
               rows.map { |row| row.fetch("argv") } == expected_commands
          fail_proof!("agent did not execute the exact nine Hive commands")
        end
        dynamic = rows.fetch(6)
        unless dynamic["dynamic_slug"] == slug
          fail_proof!("audited run command was not bound to the created slug")
        end

        folder = task_folder(slug)
        meta = YAML.safe_load(File.read(File.join(folder, "meta.yml")), aliases: false)
        unless meta.is_a?(Hash) && meta["slug"] == slug &&
               meta["workflow"] == "editorial" &&
               meta["idempotency_key"] == WORKFLOW_CREATOR_TASK_KEY
          fail_proof!("task metadata does not bind the audited task identity")
        end
        unauthorized_effects = observed_unauthorized_effects
        {
          "hive_commands" => expected_commands,
          "task_count" => task_folders.length,
          "task" => {
            "slug" => slug,
            "first_slug" => first.fetch("slug"),
            "retry_slug" => retry_result.fetch("slug"),
            "workflow" => "editorial",
            "first_created" => true,
            "retry_created" => false,
            "run_count" => rows.count { |row| row.fetch("argv").first == "run" },
            "current_stage" => File.basename(File.dirname(folder))
          },
          "effect_policy" => effect_policy_receipt,
          "effect_observations" => effect_observation_summary,
          "unauthorized_effects_observed" => unauthorized_effects,
          "external_actions" => unauthorized_effects,
          "external_actions_scope" => external_actions_scope
        }.tap do |result|
          fail_proof!("workflow-creator proof did not retain exactly one task") unless
            result.fetch("task_count") == 1
        end
      rescue Psych::Exception, Errno::ENOENT, Errno::EACCES => e
        fail_proof!("cannot inspect workflow-creator task: #{e.message}")
      end

      private

      def audit_rows
        state = audit_state
        fail_proof!("audit gateway retained a pending attempt") if state.pending
        fail_proof!("audit gateway retained a denied or failed attempt") if
          state.poisoned_terminal
        state.pairs.map { |pair| pair.fetch(:terminal) }.freeze
      end

      def audit_state
        ledger = HiveLiveAgentProof::OpenClawCreatorGatewayRuntime::AttemptLedger.new(
          path: @audit_path,
          candidate_realpath: @candidate_record.fetch("realpath"),
          candidate_sha256: @candidate_record.fetch("sha256")
        )
        ledger.read
      rescue HiveLiveAgentProof::OpenClawCreatorGatewayRuntime::InvalidLedger => e
        fail_proof!("audit gateway ledger is invalid: #{e.message}")
      end

      def result_rows
        state = audit_state
        HiveLiveAgentProof::OpenClawCreatorGatewayRuntime::ResultLedger.new(
          path: @result_path,
          safe_slug: WORKFLOW_CREATOR_SAFE_SLUG
        ).read(attempt_pairs: state.pairs)
      rescue HiveLiveAgentProof::OpenClawCreatorGatewayRuntime::InvalidLedger => e
        fail_proof!("gateway result ledger is invalid: #{e.message}")
      end

      def validation_result
        rows = result_rows.select { |row| row["kind"] == "validation" }
        fail_proof!("gateway did not retain one validation result") unless rows.length == 1

        row = rows.fetch(0)
        {
          "valid" => row.fetch("valid"),
          "stages" => row.fetch("stages"),
          "automatic_edges" => row.fetch("automatic_edges"),
          "human_outcomes" => row.fetch("human_outcomes")
        }.tap do |validation|
          expected = {
            "valid" => true,
            "stages" => %w[research draft approval],
            "automatic_edges" => [ %w[research draft], %w[draft approval] ],
            "human_outcomes" => [
              {
                "stage" => "approval", "name" => "approve", "complete" => true,
                "artifact" => "draft.md", "to" => nil
              },
              {
                "stage" => "approval", "name" => "reject", "complete" => false,
                "artifact" => nil, "to" => "draft"
              }
            ]
          }
          fail_proof!("candidate validation graph differs from the accepted graph") unless
            validation == expected
        end
      end

      def created_file_records
        root = File.join(@workspace, ".hive-state", "workflows")
        fail_proof!("created workflow tree is missing") unless regular_directory?(root)

        files = []
        directories = []
        walk_tree(root) do |path, stat|
          relative = Pathname.new(path).relative_path_from(Pathname.new(@workspace)).to_s
          if stat.directory?
            directories << relative
          elsif stat.file?
            files << relative
          else
            fail_proof!("created workflow tree contains a special entry: #{relative}")
          end
        end
        expected_directories = WORKFLOW_CREATOR_FILES.filter_map do |relative|
          parent = File.dirname(relative)
          parent unless parent == ".hive-state/workflows"
        end.uniq.sort
        control_files = files & WORKFLOW_CONTROL_FILES
        control_files.each do |relative|
          fail_proof!("workflow control file is not empty: #{relative}") unless
            File.zero?(File.join(@workspace, relative))
        end
        authored_files = files - WORKFLOW_CONTROL_FILES
        unless authored_files.sort == WORKFLOW_CREATOR_FILES.sort &&
               directories.sort == expected_directories
          fail_proof!(
            "created workflow tree contains missing or extra entries: " \
            "files=#{files.sort.inspect} directories=#{directories.sort.inspect}"
          )
        end

        WORKFLOW_CREATOR_FILES.map { |relative| file_record(relative) }
      end

      def task_folders
        stages_root = File.join(@workspace, ".hive-state", "stages")
        return [] unless File.exist?(stages_root)
        fail_proof!("task stage root is not a regular directory") unless
          regular_directory?(stages_root)

        Dir.children(stages_root).sort.flat_map do |stage_name|
          stage_path = File.join(stages_root, stage_name)
          fail_proof!("task stage entry is not a regular directory: #{stage_name}") unless
            regular_directory?(stage_path)

          Dir.children(stage_path).sort.filter_map do |task_name|
            task_path = File.join(stage_path, task_name)
            if task_name == ".gitkeep"
              unless regular_file?(task_path) && File.zero?(task_path)
                fail_proof!("task stage control entry is malformed: #{stage_name}/#{task_name}")
              end
              next
            end
            unless regular_directory?(task_path)
              fail_proof!("task entry is not a regular directory: #{stage_name}/#{task_name}")
            end
            validate_task_tree!(task_path)
            meta_path = File.join(task_path, "meta.yml")
            unless regular_file?(meta_path)
              fail_proof!("task entry is missing a regular meta.yml: #{stage_name}/#{task_name}")
            end
            task_path
          end
        end
      end

      def task_folder(slug)
        matches = task_folders.select { |path| File.basename(path) == slug }
        fail_proof!("created task slug does not resolve to one task folder") unless matches.length == 1

        matches.fetch(0)
      end

      def effect_policy_receipt
        fail_proof!("OpenClaw effect policy was not retained") unless
          @configuration && @policy_path

        config = JSON.parse(File.read(@configuration.config_path))
        approvals = JSON.parse(File.read(@configuration.approvals_path))
        policy = JSON.parse(File.read(@policy_path))
        gateway = File.join(
          config.dig("tools", "exec", "pathPrepend").to_a.fetch(0),
          "hive"
        )
        allowed = approvals.dig("agents", "main", "allowlist").to_a
        receipts = policy["tool_receipts"].to_a
        receipts_by_id = receipts.to_h { |row| [ row["id"], row ] }
        driver_sha256 = Digest::SHA256.file(OpenClawPolicyProbe::DRIVER_SOURCE_PATH).hexdigest
        successful = %w[
          inside_write inside_read inside_edit inside_apply_patch exec_hive_version
        ]
        denied = OpenClawPolicyProbe::DENIED_CONTROL_IDS
        valid = config.dig("tools", "allow") == %w[read write edit apply_patch exec] &&
                config.dig("tools", "fs", "workspaceOnly") == true &&
                config.dig("tools", "elevated", "enabled") == false &&
                config.dig("tools", "exec", "applyPatch", "enabled") == true &&
                config.dig("tools", "exec", "applyPatch", "workspaceOnly") == true &&
                config.dig("tools", "exec", "mode") == "allowlist" &&
                config.dig("tools", "exec", "host") == "gateway" &&
                config.dig("tools", "exec", "strictInlineEval") == true &&
                approvals.dig("defaults", "security") == "deny" &&
                approvals.dig("defaults", "askFallback") == "deny" &&
                approvals.dig("defaults", "autoAllowSkills") == false &&
                approvals.dig("agents", "main", "security") == "allowlist" &&
                approvals.dig("agents", "main", "ask") == "off" &&
                approvals.dig("agents", "main", "askFallback") == "deny" &&
                approvals.dig("agents", "main", "autoAllowSkills") == false &&
                allowed.length == 1 && allowed.fetch(0)["pattern"] == gateway &&
                policy["schema"] == "hive-openclaw-effective-policy" &&
                policy["schema_version"] == 2 &&
                %w[openclaw-exact-runtime public-export-contract-fixture].include?(
                  policy["source"]
                ) &&
                policy["proof_mode"] == "direct_native_tool_surface" &&
                policy["public_exports"] == OpenClawPolicyProbe::PUBLIC_EXPORTS &&
                policy["driver_sha256"] == driver_sha256 &&
                policy.dig("runtime_package", "name") == "openclaw" &&
                policy.dig("runtime_package", "version") == OPENCLAW_VERSION &&
                policy["effective_tools"] == %w[apply_patch edit exec read write] &&
                policy["workspace_only"] == true &&
                policy["apply_patch_workspace_only"] == true &&
                policy["elevated_enabled"] == false &&
                policy["exec_allowlist"] == [ gateway ] &&
                policy["unauthorized_effects_observed"] == [] &&
                policy["monitored_surfaces"].is_a?(Array) &&
                policy.dig("outside_read_caveat", "global_denial_claimed") == false &&
                receipts.map { |row| row["id"] }.uniq.length == receipts.length &&
                successful.all? {
                  |id| receipts_by_id.dig(id, "decision") == "succeeded"
                } &&
                denied.all? { |id| receipts_by_id.dig(id, "decision") == "denied" } &&
                denied.all? {
                  |id| receipts_by_id.dig(id, "mutation_observed") == false
                }
        fail_proof!("OpenClaw effect policy is not deny-by-default") unless valid

        {
          "status" => "enforced",
          "allowed_tools" => %w[read write edit apply_patch exec],
          "allowed_executables" => [ gateway ],
          "runtime_source" => policy.fetch("source"),
          "proof_mode" => policy.fetch("proof_mode"),
          "driver_sha256" => driver_sha256,
          "native_tool_receipt_sha256" => Digest::SHA256.file(@policy_path).hexdigest,
          "monitored_surfaces" => policy.fetch("monitored_surfaces"),
          "outside_read_caveat" => policy.fetch("outside_read_caveat"),
          "configuration_sha256" =>
            Digest::SHA256.file(@configuration.config_path).hexdigest,
          "approvals_sha256" =>
            Digest::SHA256.file(@configuration.approvals_path).hexdigest
        }
      rescue JSON::ParserError, KeyError, IndexError, NoMethodError,
             Errno::ENOENT, Errno::EACCES => e
        fail_proof!("cannot inspect OpenClaw effect policy: #{e.message}")
      end

      def observed_unauthorized_effects
        policy = JSON.parse(File.read(@policy_path))
        effects = effect_observation_receipt
        prohibited = policy.fetch("unauthorized_effects_observed")
        outside = effects.fetch("observations").flat_map {
          |row| row.fetch("mutations")
        }.select { |row| row["scope"] != "workspace" }
        (prohibited + outside).map do |row|
          {
            "kind" => row["kind"] || "effect",
            "operation" => row["operation"] || "observed",
            "target" => row["target"] || row["remote"]
          }
        end
      rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES => e
        fail_proof!("cannot derive unauthorized effects: #{e.message}")
      end

      def external_actions_scope
        policy = JSON.parse(File.read(@policy_path))
        {
          "derivation" => "scoped_policy_and_filesystem_observations",
          "monitored_surfaces" => [
            *policy.fetch("monitored_surfaces"),
            "workspace_before_after_snapshots"
          ].uniq,
          "observed_unadjudicated_surfaces" => [ "process_socket_snapshots" ],
          "network_authorization" => "unverified",
          "global_effect_absence_claimed" => false,
          "limitations" => [
            policy.dig("outside_read_caveat", "caveat"),
            "socket snapshots retain unattributed observations; destination identity " \
              "and authorization are not adjudicated"
          ]
        }
      rescue JSON::ParserError, KeyError, Errno::ENOENT, Errno::EACCES => e
        fail_proof!("cannot describe external-action scope: #{e.message}")
      end

      def effect_observation_summary
        effects = effect_observation_receipt
        observations = effects.fetch("observations")
        mutations = observations.flat_map { |row| row.fetch("mutations") }
        network = observed_network_effects
        policy = JSON.parse(File.read(@policy_path))
        {
          "status" => "observed",
          "policy_sha256" => Digest::SHA256.file(@policy_path).hexdigest,
          "filesystem_receipt_sha256" => Digest::SHA256.file(@effects_path).hexdigest,
          "filesystem_observation_count" => observations.length,
          "filesystem_mutation_count" => mutations.length,
          "network_observation_count" => @process_records.length,
          "network_socket_count" => network.length,
          "network_observations" => network,
          "negative_control_count" => policy.fetch("tool_receipts").count {
            |row| row["expected_decision"] == "denied"
          },
          "authoring" => authoring_contract(policy)
        }
      end

      def effect_observation_receipt
        fail_proof!("independent effect observation was not retained") unless @effects_path

        payload = JSON.parse(File.read(@effects_path))
        observations = payload["observations"]
        valid = payload["schema"] == "hive-live-agent-effect-observation" &&
                payload["schema_version"] == 1 &&
                payload["workspace"] == @workspace &&
                payload["status"] == "observed" &&
                observations.is_a?(Array) &&
                observations.map { |row| row["label"] } ==
                  %w[workflow_creation task_creation] &&
                observations.all? do |row|
                  row["status"] == "observed" && row["mutations"].is_a?(Array) &&
                    row["mutations"].all? { |mutation| mutation["scope"] == "workspace" }
                end
        fail_proof!("independent effect observation is incomplete") unless valid

        payload
      rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES => e
        fail_proof!("cannot inspect independent effects: #{e.message}")
      end

      def authoring_contract(policy)
        if policy.fetch("source") == "public-export-contract-fixture"
          fail_proof!("fixture did not retain native OpenClaw authoring proof") unless
            @authoring_path && File.file?(@authoring_path) && !File.symlink?(@authoring_path)

          payload = JSON.parse(File.read(@authoring_path))
          authored_paths = payload.fetch("tool_receipts").select {
            |row| row["operation"] == "author workflow file"
          }.map { |row| row["path"] }.sort
          valid = payload["schema"] == "hive-openclaw-native-authoring" &&
                  payload["schema_version"] == 1 &&
                  payload["source"] == "public-export-contract-fixture" &&
                  payload["proof_mode"] == "direct_native_tool_surface" &&
                  payload["model_loop"] == "not_exercised" &&
                  payload["public_exports"] == OpenClawPolicyProbe::PUBLIC_EXPORTS &&
                  payload["driver_sha256"] ==
                    Digest::SHA256.file(OpenClawPolicyProbe::DRIVER_SOURCE_PATH).hexdigest &&
                  payload.dig("runtime_package", "version") == OPENCLAW_VERSION &&
                  payload["workspace"] == @workspace &&
                  payload["unauthorized_effects_observed"] == [] &&
                  authored_paths == WORKFLOW_CREATOR_FILES.sort
          fail_proof!("fixture native OpenClaw authoring proof is invalid") unless valid

          {
            "proof_mode" => payload.fetch("proof_mode"),
            "model_loop" => payload.fetch("model_loop"),
            "driver_sha256" => payload.fetch("driver_sha256"),
            "receipt_sha256" => Digest::SHA256.file(@authoring_path).hexdigest
          }
        else
          {
            "proof_mode" => "credentialed_openclaw_agent",
            "model_loop" => "executed",
            "driver_sha256" =>
              Digest::SHA256.file(OpenClawPolicyProbe::DRIVER_SOURCE_PATH).hexdigest,
            "receipt_sha256" => nil
          }
        end
      rescue JSON::ParserError, KeyError, Errno::ENOENT, Errno::EACCES => e
        fail_proof!("cannot inspect native OpenClaw authoring proof: #{e.message}")
      end

      def observed_network_effects
        fail_proof!("network effect observation is absent") if @process_records.empty?

        @process_records.flat_map do |record|
          network = record["network"]
          unless network.is_a?(Hash) && network["status"] == "observed" &&
                 network["sample_count"].is_a?(Integer) && network["sample_count"].positive? &&
                 network["sockets"].is_a?(Array)
            fail_proof!("network effect observation is absent")
          end
          network.fetch("sockets").map do |socket|
            socket.merge(
              "kind" => "network",
              "operation" => "connection",
              "window" => record["label"],
              "classification" =>
                if %w[workflow_creation task_creation].include?(record["label"])
                  "unattributed_agent_window"
                else
                  "unattributed_process_window"
                end
            )
          end
        end
      end

      def file_record(relative)
        path = File.join(@workspace, relative)
        fail_proof!("created workflow file is empty: #{relative}") unless File.size(path).positive?

        {
          "path" => relative,
          "sha256" => Digest::SHA256.file(path).hexdigest,
          "size" => File.size(path)
        }
      end

      def walk_tree(root, &block)
        Dir.children(root).sort.each do |name|
          path = File.join(root, name)
          stat = File.lstat(path)
          fail_proof!("created workflow tree contains a symlink: #{path}") if stat.symlink?

          yield path, stat
          walk_tree(path, &block) if stat.directory?
        end
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR => e
        fail_proof!("cannot enumerate proof tree: #{e.message}")
      end

      def validate_task_tree!(root)
        walk_tree(root) do |path, stat|
          next if stat.directory? || stat.file?

          relative = Pathname.new(path).relative_path_from(Pathname.new(@workspace))
          fail_proof!("task tree contains a special entry: #{relative}")
        end
      end

      def regular_directory?(path)
        stat = File.lstat(path)
        stat.directory? && !stat.symlink?
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR
        false
      end

      def regular_file?(path)
        stat = File.lstat(path)
        stat.file? && !stat.symlink?
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR
        false
      end

      def fail_proof!(detail)
        raise Failure.new(
          phase: "verification",
          reason: "proof_contract_failed",
          detail: detail
        )
      end
    end
  end
end
