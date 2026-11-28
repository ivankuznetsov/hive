require "digest"
require "fileutils"
require "hive/agent_git_gate"
require "hive/internal_pr_checkout/result"

module Hive
  module InternalPrCheckout
    # Safe Git checkout transition and interrupted-checkout recovery (KTD9 / AE5).
    #
    # Routes every Git read and mutation through `Hive::AgentGitGate`. Proves
    # tracked index entries and worktree paths in the union of old and target
    # trees, preserves unrelated ignored build output, refuses non-ignored
    # untracked files, guards ignored-path collisions in both directions with
    # Git's `--no-overwrite-ignore` semantics, checks expected OIDs on every
    # ref move, and blocks on unexplained Git locks or third tracked states.
    module GitTransition
      LOCK_CANDIDATES = %w[
        index.lock
        HEAD.lock
        packed-refs.lock
        shallow.lock
        config.lock
        MERGE_HEAD.lock
      ].freeze

      module_function

      def capture_tree_snapshot(worktree_path, oid, gate: Hive::AgentGitGate)
        result = gate.read(worktree_path, :tree_entries, oid: oid)
        unless result.success?
          raise Error.new("git_residue_unverifiable", "could not inspect Git tree for #{oid}")
        end

        entries = {}
        result.stdout.split("\0").each do |record|
          next if record.empty?

          meta, path = record.split("\t", 2)
          next unless meta && path

          mode, type, entry_oid = meta.split(" ", 3)
          entries[path] = { "mode" => mode, "type" => type, "oid" => entry_oid.downcase }
        end
        entries
      rescue Hive::AgentGitGate::InvalidRequest => e
        raise classify_gate_invalid_request(e)
      rescue Hive::AgentGitGate::Error => e
        raise Error.new("git_residue_unverifiable", e.message)
      end

      def capture_index_snapshot(worktree_path, gate: Hive::AgentGitGate)
        result = gate.read(worktree_path, :index_entries)
        unless result.success?
          raise Error.new("git_residue_unverifiable", "could not inspect Git index entries")
        end

        entries = {}
        result.stdout.split("\0").each do |record|
          next if record.empty?

          meta, path = record.split("\t", 2)
          next unless meta && path

          mode, entry_oid, stage = meta.split(" ", 3)
          unless stage == "0"
            raise Error.new("git_residue_unverifiable", "worktree index contains unmerged stage #{stage} entry for #{path}")
          end
          entries[path] = { "mode" => mode, "oid" => entry_oid.downcase }
        end
        digest = Digest::SHA256.hexdigest(result.stdout)
        { entries: entries, digest: digest }
      rescue Hive::AgentGitGate::InvalidRequest => e
        raise classify_gate_invalid_request(e)
      rescue Hive::AgentGitGate::Error => e
        raise Error.new("git_residue_unverifiable", e.message)
      end

      def check_unexpected_git_locks!(worktree_path, branch: nil, owned_temp_paths: [],
                                      gate: Hive::AgentGitGate)
        git_dir_res = gate.read(worktree_path, :git_dir)
        common_dir_res = gate.read(worktree_path, :git_common_dir)
        unless git_dir_res.success? && common_dir_res.success?
          raise Error.new("git_residue_unverifiable", "could not resolve worktree Git directories")
        end

        git_dir = File.expand_path(git_dir_res.stdout.strip)
        common_dir = File.expand_path(common_dir_res.stdout.strip, worktree_path)
        owned = Array(owned_temp_paths).map { |p| File.expand_path(p) }

        candidates = LOCK_CANDIDATES.flat_map do |name|
          [ File.join(git_dir, name), File.join(common_dir, name) ]
        end
        if branch
          candidates << File.join(common_dir, "refs", "heads", "#{branch}.lock")
        end
        candidates.uniq.each do |lock_path|
          next unless File.exist?(lock_path) || File.symlink?(lock_path)
          next if owned.include?(File.expand_path(lock_path))

          raise Error.new(
            "git_residue_unverifiable",
            "unexpected Git lock file exists: #{File.basename(lock_path)}"
          )
        end
        true
      rescue Hive::AgentGitGate::InvalidRequest => e
        raise classify_gate_invalid_request(e)
      rescue Hive::AgentGitGate::Error => e
        raise Error.new("git_residue_unverifiable", e.message)
      end

      # Guard ignored files/directories obstructing target tracked paths before
      # mutating the checkout. Unrelated ignored build caches are permitted.
      def check_ignored_obstructions!(worktree_path, dest_tree:, tracked_index_paths: nil,
                                      allow_matching_dest_blobs: false, oid_length: 40,
                                      gate: Hive::AgentGitGate)
        ignored = read_nul_list(worktree_path, :ignored_files, gate: gate)
        return true if ignored.empty?

        tracked = tracked_index_paths || capture_index_snapshot(worktree_path, gate: gate).fetch(:entries)
        dest_paths = dest_tree.keys
        dest_dir_prefixes = directory_prefixes_of(dest_paths)

        ignored.each do |ignored_path|
          # Case 1: ignored file directly occupies a destination tracked path not currently tracked.
          if dest_tree.key?(ignored_path) && !tracked.key?(ignored_path)
            if allow_matching_dest_blobs
              observed = observe_worktree_path(File.join(worktree_path, ignored_path), oid_length: oid_length)
              next if entry_matches_worktree?(dest_tree[ignored_path], observed)
            end
            raise Error.new(
              "checkout_dirty",
              "ignored local file #{ignored_path.inspect} obstructs target commit path; preserve or remove it first"
            )
          end
          # Case 2: ignored file occupies a parent directory needed by a destination tracked path.
          if dest_dir_prefixes.include?(ignored_path) && !tracked.key?(ignored_path)
            raise Error.new(
              "checkout_dirty",
              "ignored local file #{ignored_path.inspect} obstructs target directory path; preserve or remove it first"
            )
          end
          # Case 3: ignored file lives inside a directory that destination wants to turn into a tracked file.
          each_parent_prefix(ignored_path) do |prefix|
            if dest_tree.key?(prefix) && !tracked.key?(prefix)
              raise Error.new(
                "checkout_dirty",
                "ignored local directory #{prefix.inspect} obstructs target file path; preserve or remove it first"
              )
            end
          end
        end
        true
      end

      # Execute a clean transition on an owned attached worktree from `from_oid`
      # to `to_oid`, using `--no-overwrite-ignore` and expected-OID branch ref move.
      def transition_clean!(worktree_path:, branch:, from_oid:, to_oid:,
                            from_tree:, to_tree:, gate: Hive::AgentGitGate)
        check_unexpected_git_locks!(worktree_path, branch: branch, gate: gate)

        current_branch = gate.read(worktree_path, :current_branch)
        unless current_branch.success? && current_branch.stdout.strip == branch
          raise Error.new("checkout_detached", "worktree is not attached to owned branch #{branch}")
        end
        head = gate.read(worktree_path, :head_oid)
        branch_tip = gate.read(worktree_path, :branch_oid, branch: branch)
        unless head.success? && head.stdout.strip.downcase == from_oid &&
               branch_tip.success? && branch_tip.stdout.strip.downcase == from_oid
          raise Error.new("git_residue_unverifiable", "owned worktree HEAD or branch moved before checkout")
        end
        status = gate.read(worktree_path, :status)
        unless status.success? && status.stdout.empty?
          raise Error.new("checkout_dirty", "owned worktree has uncommitted or untracked changes")
        end

        check_ignored_obstructions!(worktree_path, dest_tree: to_tree, tracked_index_paths: from_tree, gate: gate)

        gate.checkout_detached_preserving_ignored(repository_path: worktree_path, oid: to_oid)
        gate.update_branch_ref(
          repository_path: worktree_path, branch: branch, new_oid: to_oid, expected_old_oid: from_oid
        )
        gate.attach_branch_head(repository_path: worktree_path, branch: branch, expected_oid: to_oid)

        verify_clean_at!(worktree_path, branch: branch, expected_oid: to_oid, gate: gate)
        true
      rescue Hive::AgentGitGate::CheckoutRefused => e
        raise Error.new("checkout_dirty", e.message)
      rescue Hive::AgentGitGate::InvalidRequest => e
        raise classify_gate_invalid_request(e)
      rescue Hive::AgentGitGate::Error => e
        raise Error.new("git_residue_unverifiable", e.message)
      end

      # Verify an interrupted or rollback-pending worktree and converge safely
      # to `dest_oid` (either `from_oid` on rollback or `to_oid` on roll-forward).
      # Refuses any third tracked state, non-ignored untracked file, ignored
      # obstruction against `dest_oid`, or unexplained Git lock.
      def verify_and_converge!(worktree_path:, branch:, from_oid:, to_oid:, dest_oid:,
                               owned_temp_paths: [], gate: Hive::AgentGitGate)
        unless [ from_oid, to_oid ].include?(dest_oid)
          raise ArgumentError, "dest_oid must be either from_oid or to_oid"
        end
        other_oid = dest_oid == to_oid ? from_oid : to_oid

        check_unexpected_git_locks!(worktree_path, branch: branch, owned_temp_paths: owned_temp_paths, gate: gate)

        branch_res = gate.read(worktree_path, :branch_oid, branch: branch)
        unless branch_res.success?
          raise Error.new("git_residue_unverifiable", "owned branch #{branch} is missing during recovery")
        end
        current_branch_oid = branch_res.stdout.strip.downcase
        unless [ from_oid, to_oid ].include?(current_branch_oid)
          raise Error.new(
            "git_residue_unverifiable",
            "owned branch #{branch} points to unexpected commit #{current_branch_oid[0, 12]}"
          )
        end

        head_res = gate.read(worktree_path, :head_oid)
        unless head_res.success?
          raise Error.new("git_residue_unverifiable", "worktree HEAD cannot be resolved during recovery")
        end
        current_head_oid = head_res.stdout.strip.downcase
        unless [ from_oid, to_oid ].include?(current_head_oid)
          raise Error.new(
            "git_residue_unverifiable",
            "worktree HEAD points to unexpected commit #{current_head_oid[0, 12]}"
          )
        end

        sym_res = gate.read(worktree_path, :head_symbolic_ref)
        if sym_res.success? && sym_res.stdout.strip != "refs/heads/#{branch}"
          raise Error.new(
            "git_residue_unverifiable",
            "worktree HEAD is attached to unexpected ref #{sym_res.stdout.strip.inspect}"
          )
        end

        from_tree = capture_tree_snapshot(worktree_path, from_oid, gate: gate)
        to_tree = capture_tree_snapshot(worktree_path, to_oid, gate: gate)
        dest_tree = dest_oid == to_oid ? to_tree : from_tree
        other_tree = dest_oid == to_oid ? from_tree : to_tree

        untracked = read_nul_list(worktree_path, :untracked_files, gate: gate)
        outside_union = untracked.reject { |path| from_tree.key?(path) || to_tree.key?(path) }
        unless outside_union.empty?
          raise Error.new(
            "checkout_dirty",
            "worktree contains non-ignored untracked file(s) (#{outside_union.first(3).join(', ')}); recovery refused"
          )
        end

        index_snapshot = capture_index_snapshot(worktree_path, gate: gate)
        index_entries = index_snapshot.fetch(:entries)
        ignored_set = read_nul_list(worktree_path, :ignored_files, gate: gate).to_h { |p| [ p, true ] }
        validate_index_within_union!(index_entries, from_tree: from_tree, to_tree: to_tree)
        validate_worktree_within_union!(
          worktree_path,
          from_tree: from_tree,
          to_tree: to_tree,
          dest_tree: dest_tree,
          index_entries: index_entries,
          ignored_set: ignored_set,
          oid_length: from_oid.length
        )
        check_ignored_obstructions!(
          worktree_path,
          dest_tree: dest_tree,
          tracked_index_paths: index_entries,
          allow_matching_dest_blobs: true,
          oid_length: from_oid.length,
          gate: gate
        )

        if index_matches_tree?(index_entries, dest_tree) &&
           worktree_matches_tree?(
             worktree_path,
             from_tree: from_tree,
             to_tree: to_tree,
             expected_tree: dest_tree,
             index_entries: index_entries,
             ignored_set: ignored_set,
             oid_length: from_oid.length
           )
          # Already materialized at dest_oid; finish ref/HEAD alignment only.
          if current_branch_oid != dest_oid
            gate.update_branch_ref(
              repository_path: worktree_path, branch: branch, new_oid: dest_oid, expected_old_oid: current_branch_oid
            )
          end
          unless sym_res.success? && sym_res.stdout.strip == "refs/heads/#{branch}"
            gate.attach_branch_head(repository_path: worktree_path, branch: branch, expected_oid: dest_oid)
          end
          verify_clean_at!(worktree_path, branch: branch, expected_oid: dest_oid, gate: gate)
          return true
        end

        if index_matches_tree?(index_entries, other_tree) &&
           worktree_matches_tree?(worktree_path, from_tree: from_tree, to_tree: to_tree, expected_tree: other_tree, oid_length: from_oid.length) &&
           current_head_oid == other_oid
          # Cleanly at other_oid -> use Git's native `--no-overwrite-ignore` checkout!
          gate.checkout_detached_preserving_ignored(repository_path: worktree_path, oid: dest_oid)
        else
          # Proven mixed mid-checkout state within {from_tree, to_tree}.
          # Remove only proven `other_tree`-only files (or files obstructing a
          # destination directory), then reset index + checkout-index to dest_oid.
          remove_proven_other_tree_paths!(
            worktree_path, dest_tree: dest_tree, other_tree: other_tree, oid_length: from_oid.length
          )
          gate.recover_index_and_worktree(repository_path: worktree_path, target_oid: dest_oid)
        end

        if current_branch_oid != dest_oid
          gate.update_branch_ref(
            repository_path: worktree_path, branch: branch, new_oid: dest_oid, expected_old_oid: current_branch_oid
          )
        end
        gate.attach_branch_head(repository_path: worktree_path, branch: branch, expected_oid: dest_oid)
        verify_clean_at!(worktree_path, branch: branch, expected_oid: dest_oid, gate: gate)
        true
      rescue Hive::AgentGitGate::CheckoutRefused => e
        raise Error.new("checkout_dirty", e.message)
      rescue Hive::AgentGitGate::InvalidRequest => e
        raise classify_gate_invalid_request(e)
      rescue Hive::AgentGitGate::Error => e
        raise Error.new("git_residue_unverifiable", e.message)
      end

      def verify_clean_at!(worktree_path, branch:, expected_oid:, gate: Hive::AgentGitGate)
        current = gate.read(worktree_path, :current_branch)
        head = gate.read(worktree_path, :head_oid)
        branch_tip = gate.read(worktree_path, :branch_oid, branch: branch)
        status = gate.read(worktree_path, :status)
        unless current.success? && current.stdout.strip == branch &&
               head.success? && head.stdout.strip.downcase == expected_oid &&
               branch_tip.success? && branch_tip.stdout.strip.downcase == expected_oid &&
               status.success? && status.stdout.empty?
          raise Error.new("git_residue_unverifiable", "worktree post-transition state could not be verified clean at #{expected_oid[0, 12]}")
        end
        true
      end

      def validate_index_within_union!(index_entries, from_tree:, to_tree:)
        index_entries.each do |path, entry|
          allowed = [ from_tree[path], to_tree[path] ].compact
          matches = allowed.any? do |expected|
            expected["mode"] == entry["mode"] && expected["oid"] == entry["oid"]
          end
          next if matches

          raise Error.new(
            "checkout_dirty",
            "index entry for #{path.inspect} matches neither prior nor target commit (third state)"
          )
        end
      end
      private_class_method :validate_index_within_union!

      def validate_worktree_within_union!(worktree_path, from_tree:, to_tree:, dest_tree:,
                                          index_entries:, ignored_set:, oid_length:)
        union_paths = (from_tree.keys | to_tree.keys).sort
        dest_and_from_dirs = directory_prefixes_of(union_paths)

        union_paths.each do |path|
          from_entry = from_tree[path]
          to_entry = to_tree[path]
          full = File.join(worktree_path, path)
          state = observe_worktree_path(full, oid_length: oid_length)

          # An ignored local file occupying a path absent from dest_tree and the
          # index is valid under dest_tree (e.g. rolling back after an ignored
          # obstruction blocked forward checkout to the other tree).
          if !dest_tree.key?(path) && !index_entries.key?(path) && ignored_set[path]
            next
          end

          # When `path` is a file in one tree and a directory prefix of entries
          # in the other tree, a directory on disk is valid if it's a prefix in
          # the other tree (all its tracked children are checked individually).
          if state[:kind] == :directory && dest_and_from_dirs.include?(path)
            next
          end

          matches_from = entry_matches_worktree?(from_entry, state)
          matches_to = entry_matches_worktree?(to_entry, state)
          next if matches_from || matches_to

          raise Error.new(
            "checkout_dirty",
            "worktree path #{path.inspect} matches neither prior nor target commit (third state)"
          )
        end
      end
      private_class_method :validate_worktree_within_union!

      def worktree_matches_tree?(worktree_path, from_tree:, to_tree:, expected_tree:, oid_length:,
                                 index_entries: {}, ignored_set: {})
        union_paths = (from_tree.keys | to_tree.keys).sort
        expected_dirs = directory_prefixes_of(expected_tree.keys)
        union_paths.all? do |path|
          expected = expected_tree[path]
          next true if expected.nil? && !index_entries.key?(path) && ignored_set[path]

          state = observe_worktree_path(File.join(worktree_path, path), oid_length: oid_length)
          if expected.nil? && state[:kind] == :directory && expected_dirs.include?(path)
            true
          else
            entry_matches_worktree?(expected, state)
          end
        end
      end
      private_class_method :worktree_matches_tree?

      def index_matches_tree?(index_entries, tree)
        return false unless index_entries.size == tree.size

        tree.all? do |path, expected|
          actual = index_entries[path]
          actual && actual["mode"] == expected["mode"] && actual["oid"] == expected["oid"]
        end
      end
      private_class_method :index_matches_tree?

      def remove_proven_other_tree_paths!(worktree_path, dest_tree:, other_tree:, oid_length:)
        dest_dirs = directory_prefixes_of(dest_tree.keys)
        to_remove = other_tree.keys.reject { |path| dest_tree.key?(path) }
        # Also remove a file/symlink in other_tree if dest_tree needs it to be a directory.
        dest_dirs.each do |dir_path|
          to_remove << dir_path if other_tree.key?(dir_path) && !to_remove.include?(dir_path)
        end

        to_remove.each do |path|
          full = File.join(worktree_path, path)
          state = observe_worktree_path(full, oid_length: oid_length)
          next if state[:kind] == :missing
          next if state[:kind] == :directory
          next unless entry_matches_worktree?(other_tree[path], state)

          File.unlink(full)
          prune_empty_parents(File.dirname(full), stop_at: worktree_path)
        end
      end
      private_class_method :remove_proven_other_tree_paths!

      def prune_empty_parents(dir, stop_at:)
        stop = File.expand_path(stop_at)
        current = File.expand_path(dir)
        while current != stop && current.start_with?("#{stop}#{File::SEPARATOR}")
          break unless File.directory?(current) && !File.symlink?(current)
          break unless Dir.empty?(current)

          Dir.rmdir(current)
          current = File.dirname(current)
        end
      rescue SystemCallError
        nil
      end
      private_class_method :prune_empty_parents

      def observe_worktree_path(full_path, oid_length:)
        stat = File.lstat(full_path)
        if stat.symlink?
          target = File.readlink(full_path).b
          { kind: :symlink, oid: git_blob_oid(target, oid_length: oid_length) }
        elsif stat.directory?
          { kind: :directory }
        elsif stat.file?
          bytes = File.open(full_path, File::RDONLY | File::NOFOLLOW, &:read).b
          {
            kind: :file,
            executable: (stat.mode & 0o111) != 0,
            oid: git_blob_oid(bytes, oid_length: oid_length)
          }
        else
          { kind: :other }
        end
      rescue Errno::ENOENT, Errno::ENOTDIR
        { kind: :missing }
      end
      private_class_method :observe_worktree_path

      def entry_matches_worktree?(tree_entry, observed)
        return observed[:kind] == :missing if tree_entry.nil?

        case tree_entry.fetch("mode")
        when "120000"
          observed[:kind] == :symlink && observed[:oid] == tree_entry.fetch("oid")
        when "100755"
          observed[:kind] == :file && observed[:executable] == true && observed[:oid] == tree_entry.fetch("oid")
        when "100644"
          observed[:kind] == :file && observed[:executable] == false && observed[:oid] == tree_entry.fetch("oid")
        else
          false
        end
      end
      private_class_method :entry_matches_worktree?

      def git_blob_oid(bytes, oid_length:)
        header = "blob #{bytes.bytesize}\0".b
        if oid_length == 64
          Digest::SHA256.hexdigest(header + bytes)
        else
          Digest::SHA1.hexdigest(header + bytes)
        end
      end
      private_class_method :git_blob_oid

      def read_nul_list(worktree_path, operation, gate:)
        result = gate.read(worktree_path, operation)
        unless result.success?
          raise Error.new("git_residue_unverifiable", "could not inspect worktree #{operation}")
        end
        result.stdout.split("\0").reject(&:empty?)
      end
      private_class_method :read_nul_list

      def directory_prefixes_of(paths)
        prefixes = {}
        paths.each do |path|
          each_parent_prefix(path) { |prefix| prefixes[prefix] = true }
        end
        prefixes
      end
      private_class_method :directory_prefixes_of

      def each_parent_prefix(path)
        parts = path.split("/")
        return if parts.length <= 1

        (1...(parts.length)).each do |len|
          yield parts.first(len).join("/")
        end
      end
      private_class_method :each_parent_prefix

      def classify_gate_invalid_request(error)
        if error.message.include?("executable Git helpers") || error.message.include?("could not be inspected safely")
          Error.new("git_config_unsafe", error.message)
        else
          Error.new("git_residue_unverifiable", error.message)
        end
      end
      private_class_method :classify_gate_invalid_request
    end
  end
end
