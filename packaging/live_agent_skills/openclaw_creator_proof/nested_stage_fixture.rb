module HiveLiveAgentProof
  module OpenClawCreatorProof
    class NestedStageFixture
      SCHEMA = "hive-openclaw-nested-stage-fixture".freeze
      SCHEMA_VERSION = 1
      CLAUDE_VERSION = "2.1.118".freeze
      RECEIPT_MAX_BYTES = 32 * 1024
      INSTRUCTION_MAX_BYTES = WORKFLOW_CREATOR_STAGE_INSTRUCTION_MAX_BYTES
      INSTRUCTION_RELATIVE_PATH = WORKFLOW_CREATOR_STAGE_INSTRUCTION
      OUTPUT_BYTES = WORKFLOW_CREATOR_STAGE_OUTPUT

      attr_reader :path, :receipt_path, :record

      def initialize(workspace:, root:)
        @workspace = File.realpath(workspace)
        @root = File.expand_path(root)
        @path = File.join(@root, "fixture-bin", "claude")
        @receipt_path = File.join(@root, "fixture-receipts", "nested-stage.json")
      end

      def install
        FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
        FileUtils.mkdir_p(File.dirname(@receipt_path), mode: 0o700)
        write_exclusive(@path, script_source, mode: 0o500)
        @record = executable_record.freeze
        self
      rescue Errno::EACCES, Errno::EEXIST, Errno::ENOENT, Errno::ENOTDIR => e
        raise Failure.new(
          phase: "fixture",
          reason: "nested_stage_fixture_install_failed",
          detail: e.message
        )
      end

      def revalidate!
        current = executable_record
        return current if %w[configured_path realpath sha256].all? {
          |key| current.fetch(key) == @record&.fetch(key)
        }

        raise Failure.new(
          phase: "fixture",
          reason: "nested_stage_fixture_identity_changed",
          detail: "nested-stage fixture executable changed during proof execution"
        )
      rescue Failure
        raise
      rescue SystemCallError => e
        raise Failure.new(
          phase: "fixture",
          reason: "nested_stage_fixture_identity_changed",
          detail: e.message
        )
      end

      private

      def script_source
        <<~RUBY
          #!#{RbConfig.ruby}
          require "digest"
          require "json"
          require "pathname"

          WORKSPACE = #{@workspace.dump}.freeze
          RECEIPT_PATH = #{@receipt_path.dump}.freeze
          OUTPUT_BYTES = #{OUTPUT_BYTES.dump}.freeze
          INSTRUCTION_RELATIVE_PATH = #{INSTRUCTION_RELATIVE_PATH.dump}.freeze
          INSTRUCTION_MAX_BYTES = #{INSTRUCTION_MAX_BYTES}
          SAFE_SLUG = #{WORKFLOW_CREATOR_SAFE_SLUG.inspect}
          CREDENTIAL_NAMES = #{
            (
              PROVIDER_CREDENTIAL_ENV.values +
              %w[HIVE_LIVE_PROVIDER_CREDENTIAL ANTHROPIC_API_KEY CLAUDE_API_KEY]
            ).uniq.inspect
          }.freeze

          def reject!(message)
            warn "bounded nested-stage fixture rejected invocation: \#{message}"
            exit 64
          end

          def bounded_regular_bytes!(path, max_bytes:, label:)
            before = File.lstat(path)
            reject!("\#{label} is not a regular file") unless
              before.file? && !before.symlink?
            reject!("\#{label} exceeds byte budget") if before.size > max_bytes

            flags = File::RDONLY
            flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
            bytes = File.open(path, flags) do |file|
              opened = file.stat
              same_identity =
                opened.file? &&
                opened.dev == before.dev &&
                opened.ino == before.ino &&
                opened.size <= max_bytes
              reject!("\#{label} identity changed while opening") unless same_identity

              value = file.read(max_bytes + 1)
              reject!("\#{label} changed while reading") if
                value.nil? || value.bytesize > max_bytes ||
                value.bytesize != opened.size
              value
            end
            after = File.lstat(path)
            unchanged =
              after.file? &&
              !after.symlink? &&
              after.dev == before.dev &&
              after.ino == before.ino &&
              after.size == bytes.bytesize
            reject!("\#{label} identity changed after reading") unless unchanged
            bytes
          rescue SystemCallError
            reject!("\#{label} is unavailable")
          end

          if ARGV == ["--version"]
            puts "#{CLAUDE_VERSION} (Claude Code)"
            exit 0
          end

          present_credentials = CREDENTIAL_NAMES.select { |name| ENV.key?(name) }
          reject!("provider credential reached fixture") unless present_credentials.empty?

          begin
            cwd = File.realpath(Dir.pwd)
            stage_root = File.realpath(
              File.join(WORKSPACE, ".hive-state", "stages", "1-research")
            )
          rescue SystemCallError
            reject!("stage path is unavailable")
          end
          slug = File.basename(cwd)
          reject!("task slug is invalid") unless SAFE_SLUG.match?(slug)
          reject!("task folder is outside the research stage") unless
            File.dirname(cwd) == stage_root

          instruction_path = File.join(WORKSPACE, INSTRUCTION_RELATIVE_PATH)
          [
            File.join(WORKSPACE, ".hive-state"),
            File.join(WORKSPACE, ".hive-state", "workflows"),
            File.dirname(instruction_path)
          ].each do |directory|
            stat = File.lstat(directory)
            reject!("authored instruction ancestor is unsafe") unless
              stat.directory? && !stat.symlink?
          rescue SystemCallError
            reject!("authored instruction ancestor is unavailable")
          end
          instruction = bounded_regular_bytes!(
            instruction_path,
            max_bytes: INSTRUCTION_MAX_BYTES,
            label: "authored instruction"
          )
          reject!("authored instruction is empty") if instruction.empty?

          prompt = ARGV.last.to_s
          expected_argv = [
            "-p",
            "--dangerously-skip-permissions",
            "--add-dir", cwd,
            "--model", "default",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--no-session-persistence",
            prompt
          ]
          reject!("Claude argv differs from the inherited stage contract") unless
            ARGV == expected_argv

          required_prompt_fragments = [
            "You are running stage research of the hive pipeline.",
            "Working directory: the task folder",
            "State file: research.md",
            "Write the stage output to `research.md`.",
            "If the output is final, end `research.md` with a single trailing line",
            "`<!-- COMPLETE -->`.",
            "Do not modify files outside the task folder."
          ]
          missing_prompt_fragment =
            required_prompt_fragments.index { |fragment| !prompt.include?(fragment) }
          reject!("stage prompt is missing required fragment \#{missing_prompt_fragment}") if
            missing_prompt_fragment
          reject!("stage prompt does not carry the exact authored instruction") unless
            prompt.include?("Instruction:\\n\#{instruction}\\n")
          tag = prompt.match(/<(?<name>user_supplied_[0-9a-f]{16}) content_type="prior_artifacts">/)
          reject!("stage prompt lacks a bounded prior-artifact envelope") unless
            tag && prompt.include?("</\#{tag[:name]}>")
          reject!("nested-stage fixture was already invoked") if
            File.exist?(RECEIPT_PATH) || File.symlink?(RECEIPT_PATH)

          output_path = File.join(cwd, #{WORKFLOW_CREATOR_STAGE_FILE.dump})
          begin
            before_stat = File.lstat(output_path)
            reject!("stage output is not a regular file") unless
              before_stat.file? && !before_stat.symlink?
            reject!("stage output exceeds fixture input budget") if
              before_stat.size > 64 * 1024
            before_bytes = File.binread(output_path)

            flags = File::WRONLY | File::TRUNC
            flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
            File.open(output_path, flags) do |file|
              reject!("opened stage output is not a regular file") unless file.stat.file?
              written = file.write(OUTPUT_BYTES)
              reject!("stage output write was incomplete") unless
                written == OUTPUT_BYTES.bytesize
              file.flush
              file.fsync
            end
            after_stat = File.lstat(output_path)
            reject!("completed stage output changed type") unless
              after_stat.file? && !after_stat.symlink?
            after_bytes = File.binread(output_path)
            reject!("completed stage output bytes differ") unless after_bytes == OUTPUT_BYTES

            executable = File.realpath($PROGRAM_NAME)
            receipt = {
              "schema" => #{SCHEMA.dump},
              "schema_version" => #{SCHEMA_VERSION},
              "provider" => "claude",
              "provider_version" => #{CLAUDE_VERSION.dump},
              "stage" => "research",
              "workspace" => WORKSPACE,
              "instruction_path" => INSTRUCTION_RELATIVE_PATH,
              "instruction_sha256" => Digest::SHA256.hexdigest(instruction),
              "instruction_size" => instruction.bytesize,
              "task_slug" => slug,
              "task_folder" =>
                Pathname.new(cwd).relative_path_from(Pathname.new(WORKSPACE)).to_s,
              "output_file" => #{WORKFLOW_CREATOR_STAGE_FILE.dump},
              "marker" => "complete",
              "before_sha256" => Digest::SHA256.hexdigest(before_bytes),
              "after_sha256" => Digest::SHA256.hexdigest(after_bytes),
              "size" => after_bytes.bytesize,
              "prompt_sha256" => Digest::SHA256.hexdigest(prompt),
              "argv_sha256" => Digest::SHA256.hexdigest(JSON.generate(ARGV)),
              "executable_sha256" => Digest::SHA256.file(executable).hexdigest,
              "invocation_count" => 1
            }
            encoded = "\#{JSON.pretty_generate(receipt)}\\n"
            receipt_flags = File::WRONLY | File::CREAT | File::EXCL
            receipt_flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
            File.open(RECEIPT_PATH, receipt_flags, 0o600) do |file|
              reject!("fixture receipt target is not a regular file") unless file.stat.file?
              written = file.write(encoded)
              reject!("fixture receipt write was incomplete") unless
                written == encoded.bytesize
              file.flush
              file.fsync
            end
          rescue SystemCallError
            reject!("stage artifact or receipt operation failed")
          end

          puts JSON.generate(
            "type" => "result",
            "subtype" => "success",
            "is_error" => false,
            "result" => "Completed bounded research-stage fixture.",
            "usage" => {
              "input_tokens" => 0,
              "output_tokens" => 0,
              "cache_read_input_tokens" => 0,
              "cache_creation_input_tokens" => 0
            },
            "modelUsage" => {
              "hive-proof-fixture" => { "inputTokens" => 0, "outputTokens" => 0 }
            }
          )
        RUBY
      end

      def write_exclusive(path, bytes, mode:)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
          written = file.write(bytes)
          raise Errno::EIO, "incomplete nested-stage fixture write" unless
            written == bytes.bytesize

          file.flush
          file.fsync
        end
        FileUtils.chmod(mode, path)
      end

      def executable_record
        realpath = File.realpath(@path)
        stat = File.lstat(realpath)
        unless stat.file? && !stat.symlink? && File.executable?(realpath)
          raise Errno::EACCES, "nested-stage fixture is not a regular executable"
        end

        {
          "configured_path" => File.expand_path(@path),
          "realpath" => realpath,
          "sha256" => Digest::SHA256.file(realpath).hexdigest
        }
      end
    end
  end
end
