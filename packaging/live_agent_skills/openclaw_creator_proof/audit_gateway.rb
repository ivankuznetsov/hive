module HiveLiveAgentProof
  module OpenClawCreatorProof
    class AuditGateway
      attr_reader :candidate_record, :gateway_record, :audit_path, :result_path

      def initialize(candidate_path:, directory:, audit_path:, commands: WORKFLOW_CREATOR_COMMANDS,
                     workspace: nil, result_path: nil)
        @configured_candidate = candidate_path.to_s
        @directory = File.expand_path(directory)
        @audit_path = File.expand_path(audit_path)
        @result_path = File.expand_path(result_path || "#{@audit_path}.results")
        @commands = commands.map { |argv| argv.map(&:to_s).freeze }.freeze
        @workspace = workspace && File.expand_path(workspace)
      end

      def install
        validate_candidate!
        validate_dynamic_binding!
        raise Failure.new(
          phase: "gateway",
          reason: "gateway_destination_exists",
          detail: "audit gateway destination already exists: #{@directory}"
        ) if File.exist?(@directory)

        bin_dir = File.join(@directory, "bin")
        FileUtils.mkdir_p(bin_dir, mode: 0o700)
        path = File.join(bin_dir, "hive")
        write_gateway(path)
        FileUtils.chmod(0o700, path)
        @gateway_record = executable_record(path)
        path
      rescue Errno::EACCES, Errno::ENOENT, Errno::ENOTDIR => e
        raise Failure.new(
          phase: "gateway",
          reason: "gateway_install_failed",
          detail: e.message
        )
      end

      private

      def validate_candidate!
        unless Pathname.new(@configured_candidate).absolute?
          raise Failure.new(
            phase: "preflight",
            reason: "candidate_path_not_absolute",
            detail: "HIVE_PROVEN_HIVE_BIN must be absolute"
          )
        end
        unless File.file?(@configured_candidate) && File.executable?(@configured_candidate)
          raise Failure.new(
            phase: "preflight",
            reason: "candidate_not_executable",
            detail: "HIVE_PROVEN_HIVE_BIN is not executable: #{@configured_candidate}"
          )
        end

        @candidate_record = executable_record(@configured_candidate)
      rescue Errno::ELOOP, Errno::ENOENT, Errno::EACCES => e
        raise Failure.new(
          phase: "preflight",
          reason: "candidate_not_executable",
          detail: e.message
        )
      end

      def executable_record(path)
        realpath = File.realpath(path)
        {
          "configured_path" => File.expand_path(path),
          "realpath" => realpath,
          "sha256" => Digest::SHA256.file(realpath).hexdigest
        }
      end

      def validate_dynamic_binding!
        return unless @commands.include?([ "run", WORKFLOW_CREATOR_RUN_PLACEHOLDER ])
        return if @workspace && File.directory?(@workspace) && !File.symlink?(@workspace)

        raise Failure.new(
          phase: "gateway",
          reason: "dynamic_binding_unavailable",
          detail: "dynamic workflow-creator run binding requires a regular workspace"
        )
      end

      def write_gateway(path)
        candidate_realpath = @candidate_record.fetch("realpath")
        candidate_digest = @candidate_record.fetch("sha256")
        lock_path = File.join(@directory, "audit.lock")
        workspace = @workspace
        script = <<~RUBY
          #!#{RbConfig.ruby}
          require "digest"
          require "fileutils"
          require "json"
          require "open3"
          require "yaml"

          candidate = #{candidate_realpath.dump}
          expected_digest = #{candidate_digest.dump}
          commands = #{@commands.inspect}
          audit_path = #{@audit_path.dump}
          result_path = #{@result_path.dump}
          lock_path = #{lock_path.dump}
          workspace = #{workspace&.dump || "nil"}
          run_placeholder = #{WORKFLOW_CREATOR_RUN_PLACEHOLDER.dump}
          task_key = #{WORKFLOW_CREATOR_TASK_KEY.dump}
          safe_slug = #{WORKFLOW_CREATOR_SAFE_SLUG.inspect}

          def created_slug(workspace, task_key, safe_slug)
            paths = Dir.glob(
              File.join(workspace, ".hive-state", "stages", "*", "*", "meta.yml")
            ).sort
            matches = paths.filter_map do |meta_path|
              data = YAML.safe_load(File.read(meta_path), aliases: false)
              next unless data.is_a?(Hash) && data["idempotency_key"] == task_key

              slug = data["slug"].to_s
              next unless safe_slug.match?(slug) && File.basename(File.dirname(meta_path)) == slug

              slug
            rescue Psych::Exception, SystemCallError
              nil
            end.uniq
            unless matches.length == 1
              warn "workflow-creator proof could not bind one created slug"
              exit 66
            end
            matches.fetch(0)
          end

          unless File.file?(candidate) && File.executable?(candidate) &&
                 Digest::SHA256.file(candidate).hexdigest == expected_digest
            warn "workflow-creator proof candidate digest changed"
            exit 65
          end

          ordinal = nil
          FileUtils.mkdir_p(File.dirname(lock_path), mode: 0o700)
          File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
            lock.flock(File::LOCK_EX)
            ordinal = File.file?(audit_path) ? File.foreach(audit_path).count : 0
            expected = commands[ordinal]
            dynamic_slug = nil
            if expected == ["run", run_placeholder]
              dynamic_slug = created_slug(workspace, task_key, safe_slug)
              expected = ["run", dynamic_slug]
            end
            unless ARGV == expected
              warn "workflow-creator proof expected \#{expected.inspect}, got \#{ARGV.inspect}"
              exit 64
            end
            FileUtils.mkdir_p(File.dirname(audit_path), mode: 0o700)
            File.open(audit_path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |audit|
              audit.puts(JSON.generate(
                "ordinal" => ordinal + 1,
                "argv" => ARGV,
                "dynamic_slug" => dynamic_slug,
                "candidate_realpath" => candidate,
                "candidate_sha256" => expected_digest
              ))
              audit.flush
              audit.fsync
            end
          end

          unless [3, 5, 7].include?(ordinal)
            exec(candidate, *ARGV)
          end

          retained = +""
          status = nil
          Open3.popen3(candidate, *ARGV) do |input, output, error, waiter|
            input.close
            stdout_reader = Thread.new do
              loop do
                chunk = output.readpartial(16 * 1024)
                STDOUT.write(chunk)
                retained << chunk.byteslice(0, 64 * 1024 - retained.bytesize) if retained.bytesize < 64 * 1024
              end
            rescue EOFError
              nil
            end
            stderr_reader = Thread.new do
              loop { STDERR.write(error.readpartial(16 * 1024)) }
            rescue EOFError
              nil
            end
            status = waiter.value
            stdout_reader.join
            stderr_reader.join
          end

          if status.success?
            payload = retained.lines.reverse_each.filter_map do |line|
              JSON.parse(line)
            rescue JSON::ParserError
              nil
            end.find { |row| row.is_a?(Hash) }
            record =
              if ordinal == 3
                unless payload && payload["schema"] == "hive-workflow-validate" &&
                       payload["valid"] == true
                  warn "workflow-creator proof could not parse validation output"
                  exit 67
                end
                {
                  "ordinal" => ordinal + 1,
                  "kind" => "validation",
                  "valid" => true,
                  "stages" => Array(payload["stages"]).map { |stage| stage["name"] },
                  "automatic_edges" => Array(payload["automatic_edges"]).map {
                    |edge| [edge["from"], edge["to"]]
                  },
                  "human_outcomes" => payload["human_outcomes"]
                }
              else
                unless payload && payload["schema"] == "hive-new" &&
                       [true, false].include?(payload["created"]) &&
                       safe_slug.match?(payload["slug"].to_s)
                  warn "workflow-creator proof could not parse task creation output"
                  exit 67
                end
                {
                  "ordinal" => ordinal + 1,
                  "kind" => "task_creation",
                  "slug" => payload.fetch("slug"),
                  "created" => payload.fetch("created")
                }
              end
            File.open(result_path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |result|
              result.puts(JSON.generate(record))
              result.flush
              result.fsync
            end
          end
          exit(status.exitstatus || 1)
        RUBY
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o700) do |file|
          file.write(script)
        end
      end
    end
  end
end
