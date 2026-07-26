require "digest"
require "fileutils"
require "hive/errors"
require "hive/git_ref"
require "hive/managed_git"

module Hive
  # Hardened, policy-light Git operations used after an agent has edited a
  # repository. The facade deliberately exposes a closed authority vocabulary:
  # bounded repository reads, exact detached materialization, remote
  # observation, and exact expected-state publication.
  #
  # This is application-level process hardening, not a Git or operating-system
  # sandbox. Hive remains responsible for credentials, transport policy,
  # branch naming, durable intent, PR workflow, and operator approval.
  module AgentGitGate
    OID = /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
    REMOTE_NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
    SAFE_REMOTE_SCHEMES = %w[git https ssh].freeze

    class Error < Hive::Error; end
    class InvalidRequest < Error; end
    class UnsupportedOperation < InvalidRequest; end
    class CommandFailed < Error; end
    class RemoteConflict < Error; end
    class MaterializationFailed < Error; end
    class PublicationFailed < Error; end

    ReadResult = Data.define(
      :operation, :stdout, :stderr, :exitstatus, :overflow
    ) do
      def success?
        exitstatus.zero? && !overflow
      end
    end

    RemoteObservation = Data.define(
      :remote_fingerprint, :branch, :ref, :oid
    ) do
      def present?
        !oid.nil?
      end
    end

    MaterializationReceipt = Data.define(
      :destination, :oid, :disposition
    )

    PublicationReceipt = Data.define(
      :remote_fingerprint, :branch, :expected_oid, :before_oid,
      :published_oid, :after_oid
    ) do
      def success?
        after_oid == published_oid
      end
    end

    module_function

    # Execute one closed, read-only Git operation. Callers receive process
    # status as data because ancestry checks intentionally use exit 1 for
    # "false". Unknown operations and unknown arguments fail before spawn.
    def read(repository_path, operation, max_stdout_bytes: nil, **parameters)
      args = read_arguments(operation, parameters)
      out, err, status, overflow = capture(
        repository_path, args,
        max_stdout_bytes: max_stdout_bytes
      )
      ReadResult.new(
        operation: operation.to_sym,
        stdout: immutable(out),
        stderr: immutable(err),
        exitstatus: status.exitstatus,
        overflow: overflow
      )
    rescue ArgumentError, TypeError => e
      raise InvalidRequest, e.message
    end

    def observe_remote_branch(repository_path:, branch:, remote: "origin",
                              allow_local_transport: false)
      name = branch_name(branch)
      target = resolve_remote_target(
        repository_path, remote, push: false,
        allow_local_transport: allow_local_transport
      )
      observe_resolved_remote(
        repository_path, target, name,
        allow_local_transport: allow_local_transport
      )
    end

    # Materialize an already-present immutable commit into a detached worktree
    # constrained to an explicitly supplied destination root.
    def materialize(repository_path:, oid:, destination:, destination_root:)
      repository = repository_path(repository_path)
      expected = exact_oid(oid, label: "materialization OID")
      target = contained_destination(destination, destination_root)
      resolved = command!(
        repository, "rev-parse", "--verify", "#{expected}^{commit}",
        error_class: MaterializationFailed,
        message: "materialization object is unavailable"
      ).strip.downcase
      unless resolved == expected
        raise MaterializationFailed,
              "materialization object does not resolve to the exact requested commit"
      end

      paths = worktree_paths(repository)
      if File.directory?(target) && paths.include?(target)
        verify_materialization!(target, expected)
        return MaterializationReceipt.new(
          destination: immutable(target), oid: immutable(expected),
          disposition: :existing
        )
      end
      if File.exist?(target)
        raise MaterializationFailed,
              "materialization destination exists outside the repository worktree registry"
      end

      if paths.include?(target)
        command!(
          repository, "worktree", "prune", "--expire", "now",
          error_class: MaterializationFailed,
          message: "stale materialization registration could not be pruned"
        )
      end

      FileUtils.mkdir_p(File.dirname(target))
      command!(
        repository, "worktree", "add", "--detach", target, expected,
        error_class: MaterializationFailed,
        message: "exact detached materialization failed"
      )
      verify_materialization!(target, expected)
      MaterializationReceipt.new(
        destination: immutable(target), oid: immutable(expected),
        disposition: :created
      )
    rescue SystemCallError => e
      raise MaterializationFailed, "materialization filesystem operation failed: #{e.class}"
    end

    # Observe one remote ref, fetch that exact ref, reject movement, then
    # materialize the observed immutable commit. The remote target is resolved
    # again and fingerprinted so a named remote rewrite cannot redirect the
    # second half of the operation.
    def materialize_remote(repository_path:, remote:, observation:,
                           destination:, destination_root:,
                           allow_local_transport: false)
      unless observation.is_a?(RemoteObservation) && observation.present?
        raise InvalidRequest, "remote materialization requires a present RemoteObservation"
      end

      repository = repository_path(repository_path)
      target = resolve_remote_target(
        repository, remote, push: false,
        allow_local_transport: allow_local_transport
      )
      unless remote_fingerprint(target) == observation.remote_fingerprint
        raise RemoteConflict, "remote target changed after observation"
      end

      command!(
        repository, "fetch", "--no-tags", target, observation.ref,
        allow_local_transport: allow_local_transport,
        error_class: MaterializationFailed,
        message: "observed remote object could not be fetched"
      )
      fetched = command!(
        repository, "rev-parse", "--verify", "FETCH_HEAD^{commit}",
        error_class: MaterializationFailed,
        message: "fetched remote object could not be resolved"
      ).strip.downcase
      unless fetched == observation.oid
        raise RemoteConflict,
              "remote branch moved after observation; exact materialization refused"
      end

      materialize(
        repository_path: repository, oid: observation.oid,
        destination: destination, destination_root: destination_root
      )
    end

    # Publish an immutable local commit only when the remote ref matches the
    # caller's exact expected OID or exact expected absence. A successful
    # process exit is not proof: the remote is observed again and the typed
    # receipt is returned only when it names the published OID.
    def publish(repository_path:, oid:, branch:, remote: "origin",
                expected_remote_oid: nil, expected_remote_absent: false,
                allow_local_transport: false)
      published = exact_oid(oid, label: "publication OID")
      name = branch_name(branch)
      expected = publication_expectation(
        expected_remote_oid, expected_remote_absent
      )
      repository = repository_path(repository_path)

      local = command!(
        repository, "rev-parse", "--verify", "#{published}^{commit}",
        error_class: PublicationFailed,
        message: "publication object is unavailable"
      ).strip.downcase
      unless local == published
        raise PublicationFailed,
              "publication object does not resolve to the exact requested commit"
      end

      target = resolve_remote_target(
        repository, remote, push: true,
        allow_local_transport: allow_local_transport
      )
      before = observe_resolved_remote(
        repository, target, name,
        allow_local_transport: allow_local_transport
      )
      expected_before = expected_remote_absent ? nil : expected
      unless before.oid == expected_before
        raise RemoteConflict,
              "remote branch changed before exact publication"
      end

      ref = "refs/heads/#{name}"
      lease = "--force-with-lease=#{ref}:#{expected_before}"
      refspec = "#{published}:#{ref}"
      _out, _err, status, _overflow = capture(
        repository, [ "push", lease, target, refspec ],
        allow_local_transport: allow_local_transport
      )
      after = observe_resolved_remote(
        repository, target, name,
        allow_local_transport: allow_local_transport
      )
      unless after.oid == published
        if after.oid != before.oid
          raise RemoteConflict,
                "remote branch changed during exact publication"
        end
        message = status.success? ?
          "exact publication was not observable" :
          "exact publication failed"
        raise PublicationFailed, message
      end

      PublicationReceipt.new(
        remote_fingerprint: before.remote_fingerprint,
        branch: immutable(name),
        expected_oid: immutable_or_nil(expected_before),
        before_oid: immutable_or_nil(before.oid),
        published_oid: immutable(published),
        after_oid: immutable(after.oid)
      )
    rescue ArgumentError, TypeError => e
      raise InvalidRequest, e.message
    end

    # Compatibility composition helper for Hive callers that still select a
    # local branch above the boundary. The branch is resolved once and the
    # resulting immutable OID, not the mutable branch name, is published.
    def publish_local_branch(repository_path:, branch:, remote: "origin",
                             expected_remote_oid: nil,
                             expected_remote_absent: false,
                             allow_local_transport: false)
      name = branch_name(branch)
      expected = publication_expectation(
        expected_remote_oid, expected_remote_absent
      )
      oid = command!(
        repository_path(repository_path),
        "rev-parse", "--verify", "refs/heads/#{name}^{commit}",
        error_class: PublicationFailed,
        message: "local publication branch could not be resolved"
      ).strip.downcase
      publish(
        repository_path: repository_path, oid: oid, branch: name,
        remote: remote, expected_remote_oid: expected,
        expected_remote_absent: expected_remote_absent,
        allow_local_transport: allow_local_transport
      )
    end

    def remote_urls(repository_path:, remote: "origin", push: false)
      repository = repository_path(repository_path)
      name = remote_name(remote)
      args = [ "remote", "get-url" ]
      args << "--push" if push
      args.push("--all", name)
      result = read_result(repository, :remote_urls, args)
      unless result.success?
        raise CommandFailed, "remote URL lookup failed"
      end

      result.stdout.lines.map(&:strip).reject(&:empty?).map { |url| immutable(url) }.freeze
    end

    def remove_materialization(repository_path:, destination:, destination_root:)
      repository = repository_path(repository_path)
      target = contained_destination(destination, destination_root)
      registered = worktree_paths(repository)
      return :absent unless registered.include?(target) || File.exist?(target)
      unless registered.include?(target)
        raise MaterializationFailed,
              "materialization destination is not registered to this repository"
      end

      command!(
        repository, "worktree", "remove", target,
        error_class: MaterializationFailed,
        message: "materialization removal failed"
      )
      :removed
    end

    def read_arguments(operation, parameters)
      args = case operation.to_sym
      when :current_branch
        expect_parameters!(parameters)
        [ "symbolic-ref", "--quiet", "--short", "HEAD" ]
      when :head_oid
        expect_parameters!(parameters)
        [ "rev-parse", "--verify", "HEAD^{commit}" ]
      when :commit_oid
        oid = exact_oid(parameters.delete(:oid), label: "commit OID")
        expect_parameters!(parameters)
        [ "rev-parse", "--verify", "#{oid}^{commit}" ]
      when :ancestor
        base = exact_oid(parameters.delete(:base_oid), label: "base OID")
        head = exact_oid(parameters.delete(:head_oid), label: "head OID")
        expect_parameters!(parameters)
        [ "merge-base", "--is-ancestor", base, head ]
      when :commit_count
        base = exact_oid(parameters.delete(:base_oid), label: "base OID")
        head = exact_oid(parameters.delete(:head_oid), label: "head OID")
        expect_parameters!(parameters)
        [ "rev-list", "--count", "#{base}..#{head}" ]
      when :commits
        base = exact_oid(parameters.delete(:base_oid), label: "base OID")
        head = exact_oid(parameters.delete(:head_oid), label: "head OID")
        expect_parameters!(parameters)
        [ "rev-list", "--reverse", "#{base}..#{head}" ]
      when :object_list
        base = exact_oid(parameters.delete(:base_oid), label: "base OID")
        head = exact_oid(parameters.delete(:head_oid), label: "head OID")
        expect_parameters!(parameters)
        [ "rev-list", "--objects", "--no-object-names", "#{base}..#{head}" ]
      when :status
        expect_parameters!(parameters)
        [ "status", "--porcelain=v1", "--untracked-files=all", "-z" ]
      when :object_type
        oid = exact_oid(parameters.delete(:oid), label: "object OID")
        expect_parameters!(parameters)
        [ "cat-file", "-t", oid ]
      when :object_size
        spec = object_spec(parameters)
        expect_parameters!(parameters)
        [ "cat-file", "-s", spec ]
      when :object_content
        spec = object_spec(parameters)
        expect_parameters!(parameters)
        [ "cat-file", "-p", spec ]
      when :changed_paths
        base = exact_oid(parameters.delete(:base_oid), label: "base OID")
        head = exact_oid(parameters.delete(:head_oid), label: "head OID")
        expect_parameters!(parameters)
        [ "diff", "--name-only", "--diff-filter=ACMRT", "-z", base, head ]
      when :diff
        base = exact_oid(parameters.delete(:base_oid), label: "base OID")
        head = exact_oid(parameters.delete(:head_oid), label: "head OID")
        expect_parameters!(parameters)
        [ "diff", "--binary", "--full-index", base, head ]
      when :commit_patch
        oid = exact_oid(parameters.delete(:oid), label: "commit OID")
        expect_parameters!(parameters)
        [
          "show", "--format=fuller", "--no-renames", "--binary",
          oid
        ]
      when :worktree_paths
        expect_parameters!(parameters)
        [ "worktree", "list", "--porcelain" ]
      else
        raise UnsupportedOperation, "unsupported hardened Git read: #{operation}"
      end
      args.freeze
    end
    private_class_method :read_arguments

    def object_spec(parameters)
      oid = exact_oid(parameters.delete(:oid), label: "object OID")
      path = parameters.delete(:path)
      return oid if path.nil?

      value = path.to_s
      if value.empty? || value.start_with?("/") || value.match?(/[\0\r\n]/)
        raise InvalidRequest, "Git object path is invalid"
      end
      "#{oid}:#{value}"
    end
    private_class_method :object_spec

    def expect_parameters!(parameters)
      return if parameters.empty?

      raise InvalidRequest,
            "unsupported hardened Git arguments: #{parameters.keys.map(&:to_s).sort.join(', ')}"
    end
    private_class_method :expect_parameters!

    def verify_materialization!(destination, expected)
      branch = read(destination, :current_branch)
      unless branch.exitstatus == 1 && branch.stdout.empty? ||
             branch.success? && branch.stdout.strip.empty?
        raise MaterializationFailed,
              "materialized worktree is attached to a branch"
      end
      head = read(destination, :head_oid)
      unless head.success? && head.stdout.strip.downcase == expected
        raise MaterializationFailed,
              "materialized worktree does not match the exact requested commit"
      end
      status = read(destination, :status)
      unless status.success? && status.stdout.empty?
        raise MaterializationFailed, "materialized worktree is dirty"
      end

      true
    end
    private_class_method :verify_materialization!

    def worktree_paths(repository)
      result = read(repository, :worktree_paths)
      raise MaterializationFailed, "worktree registry lookup failed" unless result.success?

      result.stdout.lines.filter_map do |line|
        next unless line.start_with?("worktree ")

        realpath_or_expand(line.delete_prefix("worktree ").strip)
      end.freeze
    end
    private_class_method :worktree_paths

    def observe_resolved_remote(repository, target, branch,
                                allow_local_transport:)
      ref = "refs/heads/#{branch}"
      out, _err, status, _overflow = capture(
        repository, [ "ls-remote", "--heads", target, ref ],
        allow_local_transport: allow_local_transport
      )
      raise CommandFailed, "remote branch observation failed" unless status.success?

      lines = out.lines.map(&:strip).reject(&:empty?)
      if lines.length > 1
        raise CommandFailed, "remote branch observation returned multiple records"
      end
      oid = nil
      if lines.one?
        value, returned_ref = lines.first.split(/\s+/, 2)
        unless returned_ref == ref && value.to_s.downcase.match?(OID)
          raise CommandFailed, "remote branch observation returned an invalid record"
        end
        oid = value.downcase
      end
      RemoteObservation.new(
        remote_fingerprint: immutable(remote_fingerprint(target)),
        branch: immutable(branch),
        ref: immutable(ref),
        oid: immutable_or_nil(oid)
      )
    end
    private_class_method :observe_resolved_remote

    def resolve_remote_target(repository, remote, push:, allow_local_transport:)
      value = remote.to_s
      if value.match?(REMOTE_NAME)
        urls = remote_urls(repository_path: repository, remote: value, push: push)
        unless urls.one?
          raise InvalidRequest,
                "remote target must resolve to exactly one #{push ? 'push' : 'fetch'} URL"
        end
        value = urls.first
      end
      validate_transport_target(value, allow_local_transport: allow_local_transport)
    end
    private_class_method :resolve_remote_target

    def validate_transport_target(target, allow_local_transport:)
      value = target.to_s
      if value.empty? || value.start_with?("-") || value.match?(/[\0\r\n]/)
        raise InvalidRequest, "Git remote target is invalid"
      end
      if value.start_with?("ext::")
        raise InvalidRequest, "Git remote transport \"ext\" is not allowed"
      end
      if value.match?(/\A(?:[^@\/]+@)?[^:\/]+:.+\z/) &&
          !value.match?(/\A[a-z][a-z0-9+.-]*:\/\//i)
        return immutable(value)
      end
      if value.match?(/\A[a-z][a-z0-9+.-]*:\/\//i)
        scheme = value.split(":", 2).first.downcase
        unless SAFE_REMOTE_SCHEMES.include?(scheme)
          raise InvalidRequest, "Git remote transport #{scheme.inspect} is not allowed"
        end
        authority = value.split("://", 2).last.split("/", 2).first
        if scheme == "https" && authority.include?("@") ||
            authority.split("@", 2).first.to_s.include?(":")
          raise InvalidRequest,
                "Git remote credentials must be injected, not embedded in the target"
        end
        return immutable(value)
      end
      if allow_local_transport
        return immutable(File.expand_path(value))
      end

      raise InvalidRequest, "local Git transports are not allowed"
    end
    private_class_method :validate_transport_target

    def remote_fingerprint(target)
      Digest::SHA256.hexdigest(target)
    end
    private_class_method :remote_fingerprint

    def branch_name(value)
      Hive::GitRef.validate_branch_name(value)
    rescue ArgumentError
      raise InvalidRequest, "Git branch name is invalid"
    end
    private_class_method :branch_name

    def remote_name(value)
      name = value.to_s
      raise InvalidRequest, "Git remote name is invalid" unless name.match?(REMOTE_NAME)

      name
    end
    private_class_method :remote_name

    def exact_oid(value, label:)
      oid = value.to_s.downcase
      raise InvalidRequest, "#{label} is invalid" unless oid.match?(OID)

      oid
    end
    private_class_method :exact_oid

    def publication_expectation(expected_oid, expected_absent)
      expected = expected_oid &&
                 exact_oid(expected_oid, label: "expected remote OID")
      if expected && expected_absent
        raise InvalidRequest, "publication cannot expect both an OID and absence"
      end
      unless expected || expected_absent
        raise InvalidRequest,
              "publication requires an exact expected remote OID or absence"
      end

      expected
    end
    private_class_method :publication_expectation

    def repository_path(value)
      path = File.expand_path(value.to_s)
      raise InvalidRequest, "repository path is not a directory" unless File.directory?(path)

      path
    end
    private_class_method :repository_path

    def contained_destination(destination, root)
      declared_root = File.expand_path(root.to_s)
      target = File.expand_path(destination.to_s)
      unless File.directory?(declared_root)
        raise InvalidRequest, "materialization destination root is not a directory"
      end
      unless target.start_with?("#{declared_root}#{File::SEPARATOR}") &&
             target != declared_root
        raise InvalidRequest, "materialization destination is outside its declared root"
      end

      root_path = File.realpath(declared_root)
      ancestor = target
      ancestor = File.dirname(ancestor) until File.exist?(ancestor) ||
                                            File.symlink?(ancestor)
      ancestor_path = File.realpath(ancestor)
      unless ancestor_path == root_path ||
             ancestor_path.start_with?("#{root_path}#{File::SEPARATOR}")
        raise InvalidRequest,
              "materialization destination escapes through a symlinked ancestor"
      end
      if File.exist?(target) || File.symlink?(target)
        target_path = File.realpath(target)
        unless target_path.start_with?("#{root_path}#{File::SEPARATOR}") &&
               target_path != root_path
          raise InvalidRequest,
                "materialization destination resolves outside its declared root"
        end
      end
      target
    rescue Errno::ENOENT, Errno::ELOOP
      raise InvalidRequest, "materialization destination cannot be resolved safely"
    end
    private_class_method :contained_destination

    def realpath_or_expand(path)
      File.realpath(File.expand_path(path.to_s))
    rescue Errno::ENOENT
      File.expand_path(path.to_s)
    end
    private_class_method :realpath_or_expand

    def command!(repository, *args, allow_local_transport: false,
                 error_class:, message:)
      out, _err, status, _overflow = capture(
        repository, args, allow_local_transport: allow_local_transport
      )
      raise error_class, message unless status.success?

      out
    end
    private_class_method :command!

    def read_result(repository, operation, args)
      out, err, status, overflow = capture(repository, args)
      ReadResult.new(
        operation: operation,
        stdout: immutable(out),
        stderr: immutable(err),
        exitstatus: status.exitstatus,
        overflow: overflow
      )
    end
    private_class_method :read_result

    def capture(repository, args, max_stdout_bytes: nil,
                allow_local_transport: false)
      repository = repository_path(repository)
      validate_repository_config!(repository)
      if max_stdout_bytes
        limit = Integer(max_stdout_bytes)
        raise InvalidRequest, "max_stdout_bytes must be positive" unless limit.positive?

        Hive::ManagedGit.capture3_bounded(
          repository, *args, max_stdout_bytes: limit,
          allow_local_transport: allow_local_transport
        )
      else
        out, err, status = Hive::ManagedGit.capture3(
          repository, *args,
          allow_local_transport: allow_local_transport
        )
        [ out, err, status, false ]
      end
    end
    private_class_method :capture

    def validate_repository_config!(repository)
      unsafe, _err, status = Hive::ManagedGit.executable_local_config(repository)
      return unless status.success?
      return if unsafe.empty?

      raise InvalidRequest,
            "repository-local executable Git helpers are not allowed"
    end
    private_class_method :validate_repository_config!

    def immutable(value)
      value.to_s.dup.freeze
    end
    private_class_method :immutable

    def immutable_or_nil(value)
      value && immutable(value)
    end
    private_class_method :immutable_or_nil
  end
end
