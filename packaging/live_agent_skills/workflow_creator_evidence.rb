require "fileutils"
require "tempfile"

module HiveLiveAgentProof
  class WorkflowCreatorEvidence
    def initialize(path:, renamer: nil, linker: nil, writer: nil,
                   before_rename: nil, directory_sync: nil)
      @path = File.expand_path(path)
      @renamer = renamer || ->(source, destination) { File.rename(source, destination) }
      @linker = linker || ->(source, destination) { File.link(source, destination) }
      @writer = writer || ->(file, bytes) { file.write(bytes) }
      @before_rename = before_rename || ->(_source, _destination) { }
      @directory_sync = directory_sync || method(:fsync_directory)
    end

    def initialize!(candidate_sha:)
      document = WorkflowCreatorContract.initial(candidate_sha: candidate_sha)
      atomic_write(
        WorkflowCreatorContract.canonical_json(document),
        replace: false
      )
      document
    rescue Errno::EEXIST
      raise Error, "workflow-creator evidence already exists"
    end

    def replace_nonpassing!(document, exact_secrets: [])
      sanitized = WorkflowCreatorContract.sanitize(
        document,
        exact_secrets: exact_secrets
      )
      WorkflowCreatorContract.validate_nonpassing!(sanitized)
      atomic_write(WorkflowCreatorContract.canonical_json(sanitized))
      sanitized
    end

    def replace_success!(document, manifest:, bundle_dir:, candidate_sha:,
                         exact_secrets: [])
      sanitized = WorkflowCreatorContract.sanitize(
        document,
        exact_secrets: exact_secrets
      )
      expected_path = File.join(
        File.expand_path(bundle_dir),
        WorkflowCreatorBundle::PRIMARY_NAME
      )
      unless @path == expected_path
        raise Error, "workflow-creator evidence path does not match bundle root"
      end
      WorkflowCreatorContract.validate_success_supporting!(
        row: sanitized,
        manifest: manifest,
        candidate_sha: candidate_sha,
        bundle_dir: bundle_dir,
        exact_secrets: exact_secrets
      )
      atomic_write(WorkflowCreatorContract.canonical_json(sanitized))
      sanitized
    end

    private

    def atomic_write(bytes, replace: true)
      parent = File.dirname(@path)
      FileUtils.mkdir_p(parent, mode: 0o700)
      temporary = nil
      Tempfile.create(
        [ ".#{File.basename(@path)}-", ".tmp" ],
        parent,
        mode: File::RDWR,
        perm: 0o600
      ) do |file|
        temporary = file.path
        file.binmode
        @writer.call(file, bytes)
        file.flush
        file.fsync
        file.close
        @before_rename.call(temporary, @path)
        if replace
          @renamer.call(temporary, @path)
        else
          @linker.call(temporary, @path)
          FileUtils.rm_f(temporary)
        end
        temporary = nil
      end
      @directory_sync.call(parent)
      @path
    ensure
      FileUtils.rm_f(temporary) if temporary
    end

    def fsync_directory(path)
      File.open(path, File::RDONLY) { |directory| directory.fsync }
    rescue NotImplementedError, Errno::EINVAL, Errno::ENOTSUP, Errno::EBADF
      nil
    end
  end
end
