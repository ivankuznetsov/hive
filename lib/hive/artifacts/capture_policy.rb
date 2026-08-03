require "digest"
require "fileutils"
require "json"
require "json_schemer"
require "open3"
require "pathname"
require "securerandom"
require "time"
require "yaml"
require "hive"
require "hive/attempts/generation"
require "hive/secret_patterns"
require "hive/web/capture_runtime"
require "hive/worktree"

module Hive
  module Artifacts
    # Deterministic, generation-bound applicability decision written before the
    # artifacts agent starts. Agents may consume this receipt but cannot demote
    # it; required -> not_applicable is an explicit confirmed operator action.
    class CapturePolicy
      SCHEMA = "hive-capture-requirement".freeze
      SCHEMA_VERSION = 1
      CLASSIFIER_VERSION = "visual-paths-v1".freeze
      FILE_NAME = "capture-requirement.json".freeze
      CAPTURE_MANIFEST_MAX_BYTES = Hive::ARTIFACT_CAPTURE_MANIFEST_MAX_BYTES
      CAPTURE_MEDIA_FILE = /\A[\w.-]+\.(?:png|jpe?g|gif|webp|webm|mp4)\z/i
      VISUAL_PATH = %r{
        \A(?:
          web/|
          public/|
          app/(?:views|javascript|assets|components)/|
          .*?(?:view|template|component|screen|page|stylesheet|style|css|scss|sass)\.
        )
      }ix
      VISUAL_REQUEST = /\b(?:screenshot|screen[- ]?record|browser|visual proof|demo capture|video|gif)\b/i

      class AuthorizationError < Hive::Error; end
      class ClassificationError < Hive::Error; end

      def self.for_task(task, project:, clock: -> { Time.now.utc })
        pointer = owned_pointer(task)
        worktree = pointer && pointer["path"]
        base = pointer && (pointer["execute_base_head"] || pointer["base_oid"])
        head = worktree && git(worktree, "rev-parse", "HEAD").strip
        paths = if worktree && valid_oid?(base) && valid_oid?(head)
          changed_paths(worktree, base)
        else
          []
        end
        generation = Hive::Attempts::Generation.resolve(
          task: task,
          project: project,
          intended_stage: "7-artifacts" # coding-scoped: capture applies to the coding artifact stage
        ).task_generation
        new(
          task: task,
          project: project,
          changed_paths: paths,
          task_generation: generation,
          base_sha: valid_oid?(base) ? base : nil,
          head_sha: valid_oid?(head) ? head : nil,
          requested_outcome: requested_outcome(task),
          clock: clock
        )
      rescue Hive::WorktreeError, Hive::Error, SystemCallError
        generation = Hive::Attempts::Generation.resolve(
          task: task,
          project: project,
          intended_stage: "7-artifacts" # coding-scoped: capture applies to the coding artifact stage
        ).task_generation
        new(
          task: task, project: project, changed_paths: [],
          task_generation: generation, base_sha: nil, head_sha: nil,
          requested_outcome: requested_outcome(task), evidence_complete: false,
          clock: clock
        )
      end

      def initialize(task:, project:, changed_paths:, task_generation:, base_sha:, head_sha:,
                     requested_outcome: nil, evidence_complete: true,
                     clock: -> { Time.now.utc })
        @task = task
        @project = project.to_s
        @changed_paths = Array(changed_paths).map(&:to_s).reject(&:empty?).uniq.sort
        @task_generation = task_generation.to_s
        @base_sha = base_sha&.to_s
        @head_sha = head_sha&.to_s
        @requested_outcome = requested_outcome.to_s
        @evidence_complete = evidence_complete == true
        @clock = clock
        raise ClassificationError, "capture policy requires a task generation" if @task_generation.empty?
      end

      def build
        required_path = @changed_paths.find { |path| path.match?(VISUAL_PATH) }
        explicit = @requested_outcome.match?(VISUAL_REQUEST)
        result = required_path || explicit || !@evidence_complete ? "required" : "not_applicable"
        rationale =
          if required_path
            "User-visible path changed: #{required_path}"
          elsif explicit
            "Requested outcome explicitly asks for browser or visual proof."
          elsif !@evidence_complete
            "Hive could not prove that the implementation has no user-visible changes; capture is required."
          else
            "No deterministic user-visible path or explicit visual-proof request was observed."
          end
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "task" => @task.slug.to_s,
          "project" => @project,
          "task_generation" => @task_generation,
          "implementation_base" => @base_sha,
          "implementation_head" => @head_sha,
          "changed_paths_digest" => changed_paths_digest,
          "changed_paths" => @changed_paths,
          "classifier_version" => CLASSIFIER_VERSION,
          "result" => result,
          "rationale" => rationale,
          "override" => nil,
          "classified_at" => iso_time(@clock.call)
        }
      end

      def ensure!
        desired = build
        existing = read
        if existing && stable_identity(existing) == stable_identity(desired)
          return existing
        end

        write!(desired)
      end

      def promote!(actor:, rationale:)
        current = ensure!
        return current if current["result"] == "required"

        write!(current.merge(
          "result" => "required",
          "rationale" => rationale.to_s,
          "override" => override("promotion", actor, rationale)
        ))
      end

      def demote!(actor:, rationale:, confirmed:)
        current = ensure!
        actor = actor.to_s
        unless confirmed == true && actor.match?(/\Aoperator(?::|$)/) && !rationale.to_s.strip.empty?
          raise AuthorizationError,
                "required capture can be demoted only by a confirmed operator with a rationale"
        end
        unless current["task_generation"] == @task_generation
          raise AuthorizationError, "capture applicability changed generation; reclassify before confirming"
        end

        write!(current.merge(
          "result" => "not_applicable",
          "rationale" => rationale.to_s.strip,
          "override" => override("confirmed_demotion", actor, rationale)
        ))
      end

      def capture_satisfied?
        receipt = ensure!
        return true if receipt["result"] == "not_applicable"

        path = File.join(@task.folder, "media", "capture-manifest.json")
        stat = File.lstat(path)
        return false unless stat.file? && !stat.symlink?
        return false if stat.size > CAPTURE_MANIFEST_MAX_BYTES

        manifest = JSON.parse(File.read(path))
        valid_capture_manifest?(manifest, receipt)
      rescue JSON::ParserError, SystemCallError
        false
      end

      def path
        File.join(@task.folder, FILE_NAME)
      end

      private

      class << self
        private

        def owned_pointer(task)
          Hive::Worktree.read_owned_pointer(
            task.folder,
            project_root: task.project_root,
            slug: task.slug,
            expected_root: Hive::Worktree.canonical_root(task.project_root)
          )
        end

        def changed_paths(worktree, base)
          outputs = [
            git(worktree, "diff", "--name-only", "--no-ext-diff", "#{base}..HEAD", "--"),
            git(worktree, "diff", "--name-only", "--no-ext-diff", "--cached", "--"),
            git(worktree, "diff", "--name-only", "--no-ext-diff", "--"),
            git(worktree, "ls-files", "--others", "--exclude-standard")
          ]
          outputs.flat_map(&:lines).map(&:strip).reject(&:empty?).uniq.sort
        end

        def git(worktree, *args)
          out, err, status = Open3.capture3(
            { "GIT_CONFIG_NOSYSTEM" => "1", "GIT_TERMINAL_PROMPT" => "0" },
            "git", "-c", "core.hooksPath=/dev/null", "-c", "diff.external=",
            "-C", worktree, *args
          )
          raise Hive::Error, "capture classification Git failed: #{err.strip}" unless status.success?

          out
        end

        def requested_outcome(task)
          %w[idea.md plan.md task.md].filter_map do |name|
            path = File.join(task.folder, name)
            File.read(path, 64 * 1024).gsub(/<!--.*?-->/m, "") if File.file?(path)
          rescue SystemCallError
            nil
          end.join("\n")
        end

        def valid_oid?(value)
          value.to_s.match?(/\A[0-9a-f]{40,64}\z/i)
        end
      end

      def changed_paths_digest
        ::Digest::SHA256.hexdigest(@changed_paths.join("\0"))
      end

      def valid_capture_manifest?(manifest, receipt)
        return false unless manifest.is_a?(Hash)

        version = Integer(manifest["schema_version"], exception: false)
        return false unless [ 1, 2 ].include?(version)
        return false unless capture_manifest_schemer(version).valid?(manifest)
        return false unless manifest["status"] == "captured"
        return false unless manifest["task"].to_s == @task.slug.to_s
        return false unless manifest["source_sha"].to_s == receipt["implementation_head"].to_s
        return false unless manifest["diagnostic"].nil?
        return false unless manifest["cleanup"] == {
          "port" => "released", "processes" => "clean", "runtime" => "cleaned"
        }
        return false unless valid_capture_times?(manifest)
        return false if Hive::SecretPatterns.match?(JSON.generate(manifest))
        evidence_valid = if version == 1
          valid_v1_capture_evidence?(manifest)
        else
          valid_v2_capture_evidence?(manifest)
        end
        return false unless evidence_valid

        artifacts = Array(manifest["artifacts"])
        artifacts.any? && artifacts.all? { |artifact| valid_capture_artifact?(artifact) }
      end

      def capture_manifest_schemer(version)
        @capture_manifest_schemers ||= {}
        @capture_manifest_schemers[version] ||= JSONSchemer.schema(
          Pathname.new(Hive::Schemas.schema_path("hive-artifact-capture", version: version))
        )
      end

      def valid_v1_capture_evidence?(manifest)
        manifest["environment_keys"] == Hive::Web::CaptureRuntime::DISCLOSED_ENV_KEYS.sort &&
          !Array(manifest["command"]).empty? &&
          !Array(manifest["fixture_ids"]).empty? &&
          !Array(manifest["accessibility_assertions"]).empty?
      end

      def valid_v2_capture_evidence?(manifest)
        recorder = manifest["recorder"]
        evidence = manifest["evidence"]
        return false unless recorder.is_a?(Hash) && evidence.is_a?(Hash)
        return false if Array(recorder["command"]).empty?
        return false if Array(manifest["environment_keys"]).empty?

        case recorder["kind"]
        when "built_in"
          evidence["type"] == "hivebox" &&
            manifest["environment_keys"] == Hive::Web::CaptureRuntime::DISCLOSED_ENV_KEYS.sort &&
            !Array(evidence["fixture_ids"]).empty? &&
            !Array(evidence["accessibility_assertions"]).empty?
        when "project_provider"
          evidence["type"] == "project_provider" && evidence["details"].is_a?(Hash)
        else
          false
        end
      end

      def valid_capture_times?(manifest)
        started_at = Time.iso8601(manifest.fetch("started_at"))
        finished_at = Time.iso8601(manifest.fetch("finished_at"))
        finished_at >= started_at
      rescue ArgumentError, KeyError
        false
      end

      def valid_capture_artifact?(artifact)
        filename = artifact["file"].to_s
        return false unless File.basename(filename) == filename
        return false unless filename.match?(CAPTURE_MEDIA_FILE)

        media_root = File.realpath(File.join(@task.folder, "media"))
        candidate = File.join(media_root, filename)
        stat = File.lstat(candidate)
        return false unless stat.file? && !stat.symlink? && stat.size.positive?
        return false unless File.realpath(candidate).start_with?("#{media_root}#{File::SEPARATOR}")
        return false unless stat.size == artifact["bytes"]

        ::Digest::SHA256.file(candidate).hexdigest == artifact["sha256"].to_s
      rescue SystemCallError
        false
      end

      def read
        return nil unless File.file?(path)

        document = JSON.parse(File.read(path))
        document if document.is_a?(Hash) && document["schema"] == SCHEMA
      rescue JSON::ParserError, SystemCallError
        nil
      end

      def stable_identity(document)
        document.values_at(
          "task", "project", "task_generation", "implementation_base",
          "implementation_head", "changed_paths_digest", "classifier_version"
        )
      end

      def override(kind, actor, rationale)
        {
          "kind" => kind,
          "actor" => actor.to_s,
          "rationale" => rationale.to_s.strip,
          "confirmed_at" => iso_time(@clock.call),
          "task_generation" => @task_generation
        }
      end

      def write!(document)
        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write("#{JSON.pretty_generate(document)}\n")
          file.flush
          file.fsync
        end
        File.rename(tmp, path)
        document
      ensure
        FileUtils.rm_f(tmp) if tmp
      end

      def iso_time(value)
        value.respond_to?(:utc) ? value.utc.iso8601(6) : Time.parse(value.to_s).utc.iso8601(6)
      end
    end
  end
end
