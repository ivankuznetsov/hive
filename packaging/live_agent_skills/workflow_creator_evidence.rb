require "fileutils"
require_relative "workflow_creator_contract"
require_relative "workflow_creator_atomic_file"

module HiveLiveAgentProof
  class WorkflowCreatorEvidence
    def initialize(path:, renamer: nil, linker: nil, writer: nil,
                   before_rename: nil, after_link: nil, directory_sync: nil)
      @path = File.expand_path(path)
      @renamer = renamer || ->(_source, _destination) { }
      @linker = linker || ->(_source, _destination) { }
      @writer = writer || ->(file, bytes) { file.write(bytes) }
      @before_rename = before_rename || ->(_source, _destination) { }
      @after_link = after_link || ->(_source, _destination) { }
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
      snapshot = WorkflowCreatorContract.validate_success_supporting!(
        row: sanitized,
        manifest: manifest,
        candidate_sha: candidate_sha,
        bundle_dir: bundle_dir,
        exact_secrets: exact_secrets
      )
      atomic_write(
        WorkflowCreatorContract.canonical_json(sanitized),
        expected_parent_identity: snapshot.root_identity
      )
      sanitized
    end

    private

    def atomic_write(bytes, replace: true, expected_parent_identity: nil)
      parent = File.dirname(@path)
      FileUtils.mkdir_p(parent, mode: 0o700)
      WorkflowCreatorAtomicFile.new(
        path: @path,
        writer: @writer,
        before_publish: @before_rename,
        after_link: @after_link,
        rename_gate: @renamer,
        link_gate: @linker,
        directory_sync: @directory_sync,
        expected_parent_identity: expected_parent_identity
      ).write(bytes, replace: replace)
    rescue WorkflowCreatorAtomicFile::Unsafe,
           WorkflowCreatorAtomicFile::Unavailable => e
      raise Error, "workflow-creator evidence #{e.message}"
    rescue Errno::EEXIST
      raise
    rescue SystemCallError, IOError => e
      raise Error.new(
        "workflow-creator evidence storage operation failed " \
        "(#{e.class.name})"
      ), cause: e
    end

    def fsync_directory(directory, _path = nil)
      if directory.respond_to?(:fileno)
        IO.for_fd(directory.fileno, autoclose: false).fsync
      else
        File.open(directory, File::RDONLY) { |opened| opened.fsync }
      end
    end
  end
end
