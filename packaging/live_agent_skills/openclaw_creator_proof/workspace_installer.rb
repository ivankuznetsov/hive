module HiveLiveAgentProof
  module OpenClawCreatorProof
    class WorkspaceInstaller
      attr_reader :skill_root, :codex_path, :projection

      def initialize(workspace:, root:)
        @workspace = File.expand_path(workspace)
        @root = File.expand_path(root)
      end

      def install_skill(materialized_root:, manifest:)
        source = File.join(materialized_root, "openclaw", "hive")
        @skill_root = File.join(@workspace, "skills", "hive")
        raise Failure.new(
          phase: "skill_install",
          reason: "openclaw_projection_missing",
          detail: "materialized OpenClaw Hive skill is missing"
        ) unless File.directory?(source) && !File.symlink?(source)

        @projection = JSON.parse(File.read(File.join(source, ".hive-skill.json")))
        unless @projection["platform"] == "openclaw" &&
               @projection["skill_version"] == manifest.fetch("skill_version") &&
               @projection["canonical_digest"] == manifest.fetch("canonical_digest")
          raise Failure.new(
            phase: "skill_install",
            reason: "openclaw_projection_identity_invalid",
            detail: "OpenClaw projection does not match the candidate manifest"
          )
        end
        FileUtils.mkdir_p(File.dirname(@skill_root), mode: 0o700)
        FileUtils.cp_r(source, @skill_root, preserve: false)
        @projection.fetch("files").each do |relative, digest|
          path = HiveLiveAgentProof.relative_file!(@skill_root, relative)
          unless Digest::SHA256.file(path).hexdigest == digest
            raise Failure.new(
              phase: "skill_install",
              reason: "openclaw_projection_digest_invalid",
              detail: "OpenClaw projection file digest differs: #{relative}"
            )
          end
        end
        @skill_root
      rescue JSON::ParserError, KeyError, HiveLiveAgentProof::Error => e
        raise Failure.new(
          phase: "skill_install",
          reason: "openclaw_projection_invalid",
          detail: e.message
        )
      end

      def install_codex_fixture
        bin_dir = File.join(@root, "fixture-bin")
        FileUtils.mkdir_p(bin_dir, mode: 0o700)
        @codex_path = File.join(bin_dir, "codex")
        script = <<~RUBY
          #!#{RbConfig.ruby}
          require "json"

          if ARGV == ["--version"]
            puts "codex-cli 0.139.0"
            exit 0
          end
          unless ARGV.include?("exec")
            warn "bounded proof codex fixture accepts only exec"
            exit 64
          end
          STDIN.read
          puts({ "type" => "turn.completed", "usage" => {} }.to_json)
        RUBY
        File.open(@codex_path, File::WRONLY | File::CREAT | File::EXCL, 0o700) do |file|
          file.write(script)
        end
        FileUtils.chmod(0o700, @codex_path)
        @codex_path
      rescue Errno::EACCES, Errno::EEXIST, Errno::ENOENT => e
        raise Failure.new(
          phase: "fixture",
          reason: "codex_fixture_install_failed",
          detail: e.message
        )
      end
    end
  end
end
