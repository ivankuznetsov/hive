require "hive/atomic_file"

module Hive
  module AgentGitGate
    # Private-metadata preparation and adoption live separately from the
    # stable read/materialization/publication facade. The facade delegates to
    # this collaborator so callers retain the same closed public API.
    class Isolation
      IsolatedMetadata = Data.define(
        :source_repository, :worktree, :git_dir, :branch, :base_oid
      ) do
        def initialize(source_repository:, worktree:, git_dir:, branch:, base_oid:)
          paths = [ source_repository, worktree, git_dir ].map do |value|
            path = value.to_s
            unless !path.empty? && File.expand_path(path) == path &&
                   !path.match?(/[\0\r\n]/)
              raise InvalidRequest, "isolated Git metadata path is invalid"
            end
            path.dup.freeze
          end
          name = Hive::GitRef.validate_branch_name(branch)
          oid = base_oid.to_s.downcase
          unless oid.match?(OID)
            raise InvalidRequest, "isolated Git metadata base OID is invalid"
          end

          super(
            source_repository: paths.fetch(0), worktree: paths.fetch(1),
            git_dir: paths.fetch(2), branch: name.dup.freeze,
            base_oid: oid.dup.freeze
          )
        rescue ArgumentError, TypeError
          raise InvalidRequest, "isolated Git metadata is invalid"
        end
      end

      AdoptionReceipt = Data.define(:branch, :base_oid, :head_oid) do
        def initialize(branch:, base_oid:, head_oid:)
          name = Hive::GitRef.validate_branch_name(branch)
          base = base_oid.to_s.downcase
          head = head_oid.to_s.downcase
          unless base.match?(OID) && head.match?(OID) && base != head
            raise InvalidRequest, "isolated Git adoption OIDs are invalid"
          end

          super(
            branch: name.dup.freeze, base_oid: base.dup.freeze,
            head_oid: head.dup.freeze
          )
        rescue ArgumentError, TypeError
          raise InvalidRequest, "isolated Git adoption is invalid"
        end
      end

      class << self
        def prepare(repository_path:, worktree_path:, destination:, destination_root:)
          repository = gate_call(:repository_path, repository_path)
          worktree = gate_call(:repository_path, worktree_path)
          target = gate_call(:contained_destination, destination, destination_root)
          assert_common_repository!(repository, worktree)

          branch_result = AgentGitGate.read(worktree, :current_branch)
          unless branch_result.success? && !branch_result.stdout.strip.empty?
            raise IsolationFailed, "isolated Git metadata requires an attached worktree branch"
          end
          branch = gate_call(:branch_name, branch_result.stdout.strip)
          head = AgentGitGate.read(worktree, :head_oid)
          raise IsolationFailed, "isolated Git metadata source HEAD is unavailable" unless head.success?

          base_oid = gate_call(:exact_oid, head.stdout.strip, label: "isolated metadata base OID")
          objects = gate_call(
            :command!, repository, "rev-parse", "--path-format=absolute", "--git-path", "objects",
            error_class: IsolationFailed,
            message: "isolated Git metadata object directory is unavailable"
          ).strip
          objects = File.realpath(objects)
          unless File.directory?(objects)
            raise IsolationFailed, "isolated Git metadata object directory is unavailable"
          end

          begin
            Dir.mkdir(target, 0o700)
          rescue Errno::EEXIST
            raise IsolationFailed, "isolated Git metadata destination already exists"
          end
          _out, _err, status = Hive::ManagedGit.capture3(destination_root, "init", "--bare", target)
          raise IsolationFailed, "isolated Git metadata could not be initialized" unless status.success?

          Hive::ManagedGit.configure_isolated_worktree(git_dir: target, worktree: worktree)
          alternates = File.join(target, "objects", "info", "alternates")
          Hive::AtomicFile.write(alternates, "#{objects}\n", mode: 0o600)
          ref = "refs/heads/#{branch}"
          gate_call(
            :command!, target, "update-ref", ref, base_oid,
            error_class: IsolationFailed,
            message: "isolated Git metadata branch could not be initialized"
          )
          gate_call(
            :command!, target, "symbolic-ref", "HEAD", ref,
            error_class: IsolationFailed,
            message: "isolated Git metadata HEAD could not be initialized"
          )
          isolated_command!(
            target, worktree, "read-tree", base_oid,
            error_class: IsolationFailed,
            message: "isolated Git metadata index could not be initialized"
          )
          IsolatedMetadata.new(
            source_repository: repository, worktree: worktree, git_dir: target,
            branch: branch, base_oid: base_oid
          )
        rescue SystemCallError, IOError => e
          raise IsolationFailed,
                "isolated Git metadata filesystem operation failed: #{e.class}"
        end

        def adopt(metadata)
          unless metadata.is_a?(IsolatedMetadata)
            raise InvalidRequest, "isolated Git adoption requires IsolatedMetadata"
          end
          repository = gate_call(:repository_path, metadata.source_repository)
          worktree = gate_call(:repository_path, metadata.worktree)
          git_dir = gate_call(:repository_path, metadata.git_dir)
          assert_source_binding!(metadata, worktree)

          head = AgentGitGate.read(git_dir, :head_oid)
          raise IsolationFailed, "isolated Git metadata HEAD is unavailable" unless head.success?

          head_oid = gate_call(:exact_oid, head.stdout.strip, label: "isolated metadata HEAD OID")
          if head_oid == metadata.base_oid
            raise IsolationFailed, "isolated Git metadata contains no committed change"
          end
          status = isolated_read_result(git_dir, worktree, :status)
          unless status.success? && status.stdout.empty?
            raise IsolationFailed, "isolated Git worktree has uncommitted changes"
          end

          gate_call(
            :command!, repository, "fetch", "--no-tags", "--no-write-fetch-head", git_dir, head_oid,
            allow_local_transport: true,
            error_class: IsolationFailed,
            message: "isolated Git commit objects could not be imported"
          )
          imported = gate_call(
            :command!, repository, "rev-parse", "--verify", "#{head_oid}^{commit}",
            error_class: IsolationFailed,
            message: "imported isolated Git commit could not be resolved"
          ).strip.downcase
          unless imported == head_oid
            raise IsolationFailed, "imported isolated Git commit changed during adoption"
          end
          authoritative_ancestry = AgentGitGate.read(
            repository, :ancestor, base_oid: metadata.base_oid, head_oid: head_oid
          )
          unless authoritative_ancestry.success?
            raise IsolationFailed, "imported isolated Git commit does not descend from its base"
          end

          assert_source_binding!(metadata, worktree)
          ref = "refs/heads/#{metadata.branch}"
          adopt_transaction!(repository, worktree, ref, metadata, head_oid)
          AdoptionReceipt.new(
            branch: metadata.branch, base_oid: metadata.base_oid, head_oid: head_oid
          )
        end

        private

        def adopt_transaction!(repository, worktree, ref, metadata, head_oid)
          index_updated = false
          ref_updated = false
          begin
            gate_call(
              :command!, worktree, "read-tree", head_oid,
              error_class: IsolationFailed,
              message: "controller worktree index could not adopt isolated Git commit"
            )
            index_updated = true
            gate_call(
              :command!, repository, "update-ref", ref, head_oid, metadata.base_oid,
              error_class: IsolationFailed,
              message: "controller branch moved during isolated Git adoption"
            )
            ref_updated = true
            final_status = AgentGitGate.read(worktree, :status)
            unless final_status.success? && final_status.stdout.empty?
              raise IsolationFailed,
                    "controller worktree does not match the adopted isolated Git commit"
            end
          rescue AgentGitGate::Error => adoption_error
            restoration_errors = rollback_adoption(
              repository, worktree, ref, metadata, head_oid,
              ref_updated: ref_updated, index_updated: index_updated
            )
            detail = [ adoption_error.message, *restoration_errors ].join("; ")
            raise IsolationFailed, detail
          end
        end

        def rollback_adoption(repository, worktree, ref, metadata, head_oid,
                               ref_updated:, index_updated:)
          errors = []
          if ref_updated
            begin
              gate_call(
                :command!, repository, "update-ref", ref, metadata.base_oid, head_oid,
                error_class: IsolationFailed,
                message: "controller branch rollback failed after isolated Git adoption"
              )
            rescue AgentGitGate::Error => error
              errors << error.message
            end
          end
          if index_updated
            begin
              restore_adoption_index(worktree, metadata.base_oid)
            rescue AgentGitGate::Error => error
              errors << error.message
            end
          end
          errors
        end

        def isolated_read_result(git_dir, worktree, operation)
          args = gate_call(:read_arguments, operation, {})
          gate_call(:validate_repository_config!, git_dir)
          out, err, status = Hive::ManagedGit.capture3_isolated(git_dir, worktree, *args)
          ReadResult.new(
            operation: operation, stdout: gate_call(:immutable, out),
            stderr: gate_call(:immutable, err), exitstatus: status.exitstatus,
            overflow: false
          )
        rescue ArgumentError, TypeError => e
          raise InvalidRequest, e.message
        end

        def isolated_command!(git_dir, worktree, *args, error_class:, message:)
          gate_call(:validate_repository_config!, git_dir)
          out, _err, status = Hive::ManagedGit.capture3_isolated(git_dir, worktree, *args)
          raise error_class, message unless status.success?

          out
        end

        def assert_source_binding!(metadata, worktree)
          assert_common_repository!(metadata.source_repository, worktree)
          branch = AgentGitGate.read(worktree, :current_branch)
          unless branch.success? && branch.stdout.strip == metadata.branch
            raise IsolationFailed, "controller worktree branch changed before isolated Git adoption"
          end
          head = AgentGitGate.read(worktree, :head_oid)
          unless head.success? && head.stdout.strip.downcase == metadata.base_oid
            raise IsolationFailed, "controller worktree HEAD changed before isolated Git adoption"
          end
          true
        end

        def assert_common_repository!(source_repository, worktree)
          source_common = gate_call(
            :command!, source_repository, "rev-parse", "--path-format=absolute", "--git-common-dir",
            error_class: IsolationFailed,
            message: "isolated Git source repository is unavailable"
          ).strip
          worktree_common = gate_call(
            :command!, worktree, "rev-parse", "--path-format=absolute", "--git-common-dir",
            error_class: IsolationFailed,
            message: "isolated Git worktree repository is unavailable"
          ).strip
          unless File.realpath(source_common) == File.realpath(worktree_common)
            raise IsolationFailed, "isolated Git worktree no longer belongs to its source repository"
          end
          true
        rescue SystemCallError
          raise IsolationFailed, "isolated Git repository binding is unavailable"
        end

        def restore_adoption_index(worktree, oid)
          gate_call(
            :command!, worktree, "read-tree", oid,
            error_class: IsolationFailed,
            message: "controller worktree index restoration failed"
          )
        end

        def gate_call(method, *args, **kwargs)
          AgentGitGate.send(method, *args, **kwargs)
        end
      end
    end
  end
end
