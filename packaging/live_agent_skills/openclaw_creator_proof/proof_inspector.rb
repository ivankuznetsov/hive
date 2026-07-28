module HiveLiveAgentProof
  module OpenClawCreatorProof
    class ProofInspector
      def initialize(workspace:, audit_path:, result_path:, candidate_record:)
        @workspace = File.expand_path(workspace)
        @audit_path = File.expand_path(audit_path)
        @result_path = File.expand_path(result_path)
        @candidate_record = candidate_record
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
          }
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
                  row["candidate_sha256"] == @candidate_record.fetch("sha256")
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
        WORKFLOW_CREATOR_FILES.map do |relative|
          path = File.join(@workspace, relative)
          fail_proof!("missing created workflow file #{relative}") unless
            File.file?(path) && !File.symlink?(path) && File.size(path).positive?

          {
            "path" => relative,
            "sha256" => Digest::SHA256.file(path).hexdigest,
            "size" => File.size(path)
          }
        end
      end

      def task_folders
        Dir.glob(File.join(@workspace, ".hive-state", "stages", "*", "*")).select do |path|
          File.directory?(path) && File.file?(File.join(path, "meta.yml"))
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
