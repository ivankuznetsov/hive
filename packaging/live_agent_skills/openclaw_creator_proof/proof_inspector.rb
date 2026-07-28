module HiveLiveAgentProof
  module OpenClawCreatorProof
    class ProofInspector
      WORKFLOW_CONTROL_FILES = [ ".hive-state/workflows/.mutation.lock" ].freeze

      def initialize(workspace:, audit_path:, result_path:, candidate_record:,
                     configuration: nil)
        @workspace = File.expand_path(workspace)
        @audit_path = File.expand_path(audit_path)
        @result_path = File.expand_path(result_path)
        @candidate_record = candidate_record
        @configuration = configuration
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
          "external_actions" => observed_external_actions
        }.tap do |result|
          fail_proof!("workflow-creator proof did not retain exactly one task") unless
            result.fetch("task_count") == 1
        end
      rescue Psych::Exception, Errno::ENOENT, Errno::EACCES => e
        fail_proof!("cannot inspect workflow-creator task: #{e.message}")
      end

      private

      def audit_rows
        rows = read_json_lines(@audit_path)
        rows.each_with_index do |row, index|
          valid = row.is_a?(Hash) && row["ordinal"] == index + 1 &&
                  row["argv"].is_a?(Array) &&
                  row["candidate_realpath"] == @candidate_record.fetch("realpath") &&
                  row["candidate_sha256"] == @candidate_record.fetch("sha256") &&
                  row["success"] == true && row["exit_status"] == 0 &&
                  row["signal"].nil?
          fail_proof!("audit gateway identity or ordinal is invalid") unless valid
        end
        rows
      end

      def result_rows
        read_json_lines(@result_path)
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

      def read_json_lines(path)
        return [] unless File.file?(path) && !File.symlink?(path)

        File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
      rescue JSON::ParserError, Errno::EACCES => e
        fail_proof!("cannot read proof audit: #{e.message}")
      end

      def effect_policy_receipt
        fail_proof!("OpenClaw effect policy was not retained") unless @configuration

        config = JSON.parse(File.read(@configuration.config_path))
        approvals = JSON.parse(File.read(@configuration.approvals_path))
        gateway = File.join(
          config.dig("tools", "exec", "pathPrepend").to_a.fetch(0),
          "hive"
        )
        allowed = approvals.dig("agents", "main", "allowlist").to_a
        valid = config.dig("tools", "allow") == [ "exec" ] &&
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
                allowed.length == 1 && allowed.fetch(0)["pattern"] == gateway
        fail_proof!("OpenClaw effect policy is not deny-by-default") unless valid

        {
          "status" => "enforced",
          "allowed_tools" => [ "exec" ],
          "allowed_executables" => [ gateway ],
          "configuration_sha256" =>
            Digest::SHA256.file(@configuration.config_path).hexdigest,
          "approvals_sha256" =>
            Digest::SHA256.file(@configuration.approvals_path).hexdigest
        }
      rescue JSON::ParserError, KeyError, IndexError, NoMethodError,
             Errno::ENOENT, Errno::EACCES => e
        fail_proof!("cannot inspect OpenClaw effect policy: #{e.message}")
      end

      def observed_external_actions
        effect_policy_receipt
        []
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
