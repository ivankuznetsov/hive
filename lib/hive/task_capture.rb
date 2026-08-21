require "digest"
require "fileutils"
require "json"
require "hive/git_ops"
require "hive/lock"
require "hive/markers"
require "hive/task_counter"
require "hive/task_meta"
require "hive/workflows"
require "hive/workflow_package/managed_store"

module Hive
  # Lower-level deterministic task capture shared by CLI task creation and
  # controller-owned materializers. Callers resolve the workflow and provide
  # the exact initial-state bytes; this service owns idempotency, lock order,
  # metadata admission, commit, and rollback.
  class TaskCapture
    Result = Data.define(:folder, :created)
    Attachment = Data.define(:snapshot_path, :destination, :name, :sha256)
    SLUG = /\A[a-z][a-z0-9-]{0,62}[a-z0-9]\z/

    class TypedValueError < Hive::Error
      attr_reader :value

      def initialize(message, value: nil)
        @value = value
        super(message)
      end
    end

    class IdempotencyConflict < TypedValueError
      def exit_code = Hive::ExitCodes::USAGE
    end
    class SlugCollisionError < TypedValueError; end
    class InvalidAttachmentError < TypedValueError; end

    def initialize(project_root:, hive_state:, workflow_info:, slug:, state_bytes:,
                   idempotency_key:, input_fingerprint:, attachments: [],
                   depends_on: nil, base_branch: nil, initial_marker: nil,
                   git_ops: nil, task_id_provider: nil, before_lookup: nil,
                   before_candidate: nil, candidate_writer: nil)
      @project_root = File.expand_path(project_root)
      @hive_state = File.expand_path(hive_state)
      @workflow_info = workflow_info
      @workflow = workflow_info.fetch(:descriptor)
      @slug = slug.to_s
      @state_bytes = String(state_bytes).b.freeze
      @idempotency_key = idempotency_key.to_s
      @input_fingerprint = input_fingerprint.to_s
      @attachments = Array(attachments).freeze
      @depends_on = depends_on
      @base_branch = base_branch
      @initial_marker = initial_marker
      @git_ops = git_ops || Hive::GitOps.new(@project_root)
      @task_id_provider = task_id_provider || -> { Hive::TaskCounter.next_or_nil }
      @before_lookup = before_lookup
      @before_candidate = before_candidate
      @candidate_writer = candidate_writer
    end

    def call
      validate_inputs!
      store = Hive::WorkflowPackage::ManagedStore.new(@hive_state)
      store.with_stable_selection(
        @workflow.id.to_s, cfg: @workflow_info.fetch(:managed_cfg, {})
      ) do |stable_selection|
        validate_stable_selection!(stable_selection)
        Hive::Lock.with_commit_lock(@hive_state) do
          validate_stable_authored_workflow!
          @before_lookup&.call
          existing = find_idempotent_task!
          validate_stable_authored_workflow!
          return Result.new(folder: existing.fetch(:folder), created: false) if existing

          task_dir = task_folder
          @before_candidate&.call(task_dir)
          create_candidate!(task_dir, stable_selection: stable_selection)
          begin
            @git_ops.hive_commit(
              stage_name: @workflow.stages.first.dir,
              slug: @slug,
              action: "captured"
            )
          rescue StandardError, Interrupt
            cleanup_failed_commit!(task_dir)
            raise
          end
          Result.new(folder: task_dir, created: true)
        end
      end
    end

    private

    def validate_inputs!
      unless @slug.match?(SLUG) && !@slug.include?("..") && !@slug.include?("/")
        raise SlugCollisionError.new("unsafe task slug #{@slug.inspect}", value: @slug)
      end
      unless !@idempotency_key.empty? && @idempotency_key.valid_encoding? &&
             @idempotency_key.bytesize <= 512
        raise IdempotencyConflict.new(
          "idempotency key must be non-empty UTF-8 text no longer than 512 bytes",
          value: @idempotency_key
        )
      end
      unless @input_fingerprint.match?(/\A[0-9a-f]{64}\z/)
        raise IdempotencyConflict.new(
          "input fingerprint must be a lowercase SHA-256 digest",
          value: @idempotency_key
        )
      end
      unless @workflow.stages.first
        raise Hive::ConfigError, "task workflow has no entry stage"
      end
      @attachments.each { |attachment| validate_attachment!(attachment) }
    end

    def validate_attachment!(attachment)
      name = attachment.name.to_s
      digest = attachment.sha256.to_s
      unless !name.empty? && name != "." && name != ".." &&
             name == File.basename(name) && digest.match?(/\A[0-9a-f]{64}\z/)
        raise InvalidAttachmentError.new(
          "invalid attachment snapshot",
          value: attachment.destination.to_s
        )
      end
    end

    def task_folder
      File.join(@hive_state, "stages", @workflow.stages.first.dir, @slug)
    end

    def find_idempotent_task!
      matches = idempotency_metadata_paths.filter_map do |path|
        folder = File.dirname(path)
        read = Hive::TaskMeta.read_for_admission(folder)
        unless read.status == :ok
          raise IdempotencyConflict.new(
            "cannot prove idempotency while task metadata is unreadable at #{path}: " \
            "#{read.error || read.status}",
            value: @idempotency_key
          )
        end
        { folder: folder, meta: read.data } if
          read.data[:idempotency_key] == @idempotency_key
      end
      return nil if matches.empty?
      if matches.length > 1
        raise IdempotencyConflict.new(
          "idempotency key #{@idempotency_key.inspect} is already attached to multiple tasks; " \
          "repair metadata before retrying",
          value: @idempotency_key
        )
      end
      return matches.first if
        matches.first.dig(:meta, :input_fingerprint) == @input_fingerprint

      raise IdempotencyConflict.new(
        "idempotency key #{@idempotency_key.inspect} was already used for different input or workflow",
        value: @idempotency_key
      )
    end

    def idempotency_metadata_paths
      Dir.glob(File.join(@hive_state, "stages", "*", "*", Hive::TaskMeta::FILENAME))
    end

    def idempotency_key = @idempotency_key

    def create_candidate!(task_dir, stable_selection:)
      created = false
      FileUtils.mkdir_p(File.dirname(task_dir))
      Dir.mkdir(task_dir)
      created = true
      state_path = File.join(task_dir, @workflow.stages.first.state_file)
      File.binwrite(state_path, @state_bytes)
      if @initial_marker
        Hive::Markers.set(
          state_path,
          @initial_marker.fetch(:name),
          @initial_marker.fetch(:attrs, {})
        )
      end
      copy_attachments!(task_dir)
      @candidate_writer&.call(task_dir)
      validate_stable_authored_workflow!
      write_task_meta!(task_dir, stable_selection: stable_selection)
    rescue Errno::EEXIST
      if created
        FileUtils.rm_rf(task_dir)
        raise
      end
      raise SlugCollisionError.new(
        "slug collision at #{task_dir} (rare; retry the command)",
        value: @slug
      )
    rescue StandardError, Interrupt
      FileUtils.rm_rf(task_dir) if created
      raise
    end

    def copy_attachments!(task_dir)
      return if @attachments.empty?

      assets_dir = File.join(task_dir, "assets")
      FileUtils.mkdir_p(assets_dir)
      @attachments.each do |attachment|
        destination = File.join(assets_dir, attachment.name)
        FileUtils.cp(attachment.snapshot_path, destination)
        next if Digest::SHA256.file(destination).hexdigest == attachment.sha256

        raise InvalidAttachmentError.new(
          "attachment snapshot changed while creating the task",
          value: attachment.destination
        )
      end
    end

    def write_task_meta!(task_dir, stable_selection:)
      managed = @workflow_info.fetch(:managed)
      validate_stable_selection!(stable_selection)
      Hive::TaskMeta.write(
        task_dir,
        id: @task_id_provider.call,
        slug: @slug,
        display_name: nil,
        depends_on: @depends_on,
        base_branch: @base_branch,
        workflow: @workflow_info.fetch(:pin) ? @workflow.id.to_s : nil,
        workflow_commit: managed&.fetch("source_commit"),
        workflow_manifest_digest: managed&.fetch("manifest_digest"),
        workflow_configuration_digest: managed&.fetch("configuration_digest"),
        idempotency_key: @idempotency_key,
        input_fingerprint: @input_fingerprint,
        plan_review_required: Hive::Workflows.coding_id?(@workflow.id) ? true : nil
      )
    end

    def validate_stable_selection!(current)
      managed = @workflow_info.fetch(:managed)
      return unless managed
      return if current &&
        current.fetch("source_commit") == managed.fetch("source_commit") &&
        current.fetch("manifest_digest") == managed.fetch("manifest_digest") &&
        current.fetch("configuration_digest") == managed.fetch("configuration_digest")

      raise Hive::ConcurrentRunError.new(
        "managed workflow selection changed while creating the task"
      )
    end

    def validate_stable_authored_workflow!
      expected = @workflow_info[:authored_digest]
      return unless expected
      return if authored_workflow_digest == expected

      raise Hive::ConcurrentRunError,
            "owner-authored workflow changed while creating the task; retry against the current descriptor"
    end

    def authored_workflow_digest
      workflows = File.join(@hive_state, "workflows")
      descriptor_path = File.join(workflows, "#{@workflow.id}.yml")
      return nil unless File.file?(descriptor_path)

      instruction_root = File.join(workflows, @workflow.id.to_s)
      paths = [ descriptor_path ]
      if File.directory?(instruction_root)
        paths.concat(
          Dir.glob(File.join(instruction_root, "**", "*"), File::FNM_DOTMATCH)
             .select { |path| File.file?(path) }
        )
      end
      entries = paths.sort.map do |path|
        [ path.delete_prefix("#{workflows}/"), Digest::SHA256.file(path).hexdigest ]
      end
      Digest::SHA256.hexdigest(JSON.generate(entries))
    end

    def cleanup_failed_commit!(task_dir)
      FileUtils.rm_rf(task_dir)
      relative = task_dir.delete_prefix("#{@hive_state}/")
      @git_ops.run_git!("-C", @hive_state, "reset", "-q", "HEAD", "--", relative)
    end
  end
end
