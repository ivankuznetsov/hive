require "yaml"
require "hive/agent_git_gate"
require "hive/config"
require "hive/gh"
require "hive/git_ref"
require "hive/workflows"
require "hive/worktree"
require "hive/internal_pr_checkout/result"

module Hive
  module InternalPrCheckout
    # Authoritative identity predicate and deterministic target derivation for
    # Hive-owned internal PR review tasks (`source: ad-hoc`).
    #
    # Pointer and sidecar bytes supply observations only. Expected worktree
    # path, local branch, PR ref, and canonical remote repository are derived
    # independently from validated task and project identity.
    module Identity
      SOURCE = "ad-hoc".freeze
      REVIEW_STAGE_NAMES = %w[review 6-review].freeze
      SLUG_PATTERN = /\Aadhoc-review-pr-([1-9][0-9]*)\z/
      OID_PATTERN = /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
      STORE_DIR = "internal-pr-checkout".freeze
      CURRENT_FILE = "current.json".freeze
      PENDING_FILE = "pending.json".freeze
      CANDIDATE_FILE = "candidate.json".freeze
      HISTORY_ROOT_FILE = "history-root.json".freeze
      GRANT_INDEX_FILE = "grant-index.json".freeze
      MANIFESTS_DIR = "manifests".freeze
      PR_FILE_MAX_BYTES = 256 * 1024
      JSON_RECORD_MAX_BYTES = 256 * 1024

      Resolved = Data.define(
        :task_folder,
        :project_root,
        :project_name,
        :task_id,
        :task_slug,
        :pr_number,
        :pr_url,
        :pr_host,
        :pr_repository,
        :base_ref_name,
        :head_ref_name,
        :head_repository,
        :is_cross_repository,
        :pr_state,
        :pr_head_oid,
        :pr_head_oid_legacy,
        :expected_root,
        :expected_worktree_path,
        :expected_branch,
        :allow_local_transport
      )

      module_function

      def slug_for(pr_number)
        number = positive_pr_number!(pr_number)
        "adhoc-review-pr-#{number}"
      end

      def branch_for(pr_number)
        number = positive_pr_number!(pr_number)
        "hive/review/pr-#{number}"
      end

      def worktree_path_for(project_root, slug, config: nil)
        File.join(Hive::Worktree.canonical_root(project_root, config: config), slug.to_s)
      end

      def quarantine_ref_for(transaction_id)
        "refs/hive/internal-pr-checkout/tx/#{validated_token!(transaction_id, 'transaction_id')}"
      end

      def candidate_archive_ref_for(pr_number:, generation:, transaction_id:)
        number = positive_pr_number!(pr_number)
        gen = Integer(generation)
        raise ArgumentError, "generation must be positive" unless gen.positive?

        token = validated_token!(transaction_id, "transaction_id")
        "refs/hive/internal-pr-checkout/candidates/pr-#{number}/gen-#{gen}-#{token}"
      end

      def retirement_label_for(transaction_id:, target_oid:)
        token = validated_token!(transaction_id, "transaction_id")[0, 12]
        oid = target_oid.to_s.downcase
        raise ArgumentError, "target_oid is invalid" unless oid.match?(OID_PATTERN)

        "internal-pr-reopen-#{oid[0, 12]}-#{token}"
      end

      def store_dir(task_folder)
        File.join(File.expand_path(task_folder.to_s), STORE_DIR)
      end

      def current_path(task_folder)
        File.join(store_dir(task_folder), CURRENT_FILE)
      end

      def pending_path(task_folder)
        File.join(store_dir(task_folder), PENDING_FILE)
      end

      def candidate_path(task_folder)
        File.join(store_dir(task_folder), CANDIDATE_FILE)
      end

      def history_root_path(task_folder)
        File.join(store_dir(task_folder), HISTORY_ROOT_FILE)
      end

      def grant_index_path(task_folder)
        File.join(store_dir(task_folder), GRANT_INDEX_FILE)
      end

      def manifests_dir(task_folder)
        File.join(store_dir(task_folder), MANIFESTS_DIR)
      end

      # Fast non-mutating check for whether `task` belongs to the internal PR
      # review domain (applicable — though its sidecars may still fail strict
      # validation when reconciled).
      def applicable?(task, allow_any_stage: false)
        return false unless task && task.respond_to?(:folder)
        return false if task.folder.to_s.empty?
        if task.respond_to?(:workflow) && task.workflow
          workflow_id = task.workflow.respond_to?(:id) ? task.workflow.id : task.workflow
          return false unless Hive::Workflows.coding_id?(workflow_id)
        end
        unless allow_any_stage
          stage = task.respond_to?(:stage_name) ? task.stage_name.to_s : File.basename(File.dirname(task.folder))
          return false unless REVIEW_STAGE_NAMES.include?(stage)
        end

        folder = File.expand_path(task.folder)
        return true if File.exist?(current_path(folder)) || File.symlink?(current_path(folder))
        return true if File.exist?(pending_path(folder)) || File.symlink?(pending_path(folder))

        pr_path = File.join(folder, "pr.md")
        return true if frontmatter_source_adhoc?(pr_path)
        return true if frontmatter_source_adhoc?(File.join(folder, "task.md"))
        return true if frontmatter_source_adhoc?(File.join(folder, "idea.md"))

        false
      rescue StandardError
        # An unreadable or malformed pr.md / store directory on an adhoc-slugged
        # review task still routes into strict validation so it fails closed.
        slug = task.respond_to?(:slug) ? task.slug.to_s : File.basename(task.folder.to_s)
        slug.match?(SLUG_PATTERN)
      end

      # Strictly validate and derive expected local/remote targets for an
      # applicable internal PR review task. Raises InternalPrCheckout::Error
      # with closed R2 reason codes on any violation.
      def resolve!(task, config: nil, allow_legacy_head_ref_oid: true, allow_local_transport: nil)
        folder = File.expand_path(task.folder.to_s)
        project_root = File.expand_path(task.project_root.to_s)
        project_name = task.respond_to?(:project_name) ? task.project_name.to_s : File.basename(project_root)
        slug = task.slug.to_s
        task_id = task.respond_to?(:id) ? task.id&.to_s : nil
        cfg = config || Hive::Config.load(project_root)

        pr_path = File.join(folder, "pr.md")
        pr_fm = read_strict_frontmatter!(pr_path, label: "pr.md")

        source = pr_fm["source"].to_s.strip
        unless source.casecmp?(SOURCE)
          raise Error.new(
            "pr_metadata_invalid",
            "pr.md source must be #{SOURCE.inspect} for an internal PR review task"
          )
        end

        raw_number = pr_fm["pr_number"]
        pr_number = begin
          num = Integer(raw_number)
          num.positive? ? num : nil
        rescue ArgumentError, TypeError
          nil
        end
        unless pr_number
          raise Error.new("pr_metadata_invalid", "pr.md pr_number is missing or invalid")
        end

        expected_slug = slug_for(pr_number)
        unless slug == expected_slug
          raise Error.new(
            "sidecar_inconsistent",
            "task slug #{slug.inspect} does not match deterministic internal PR slug #{expected_slug.inspect}"
          )
        end

        parsed_url = Hive::Gh.parse_pull_request_url(pr_fm["pr_url"])
        unless parsed_url && parsed_url.fetch("number") == pr_number
          raise Error.new(
            "pr_metadata_invalid",
            "pr.md pr_url is missing, non-canonical, or disagrees with pr_number ##{pr_number}"
          )
        end

        validate_sibling_sidecars!(folder, expected_slug: expected_slug, expected_url: parsed_url.fetch("url"))

        has_canonical = !pr_fm["head_oid"].to_s.strip.empty?
        has_legacy = !pr_fm["head_ref_oid"].to_s.strip.empty?
        pr_head_oid = begin
          Hive::Gh.read_pr_head_oid(pr_fm, allow_legacy: allow_legacy_head_ref_oid)
        rescue Hive::GhError => e
          raise Error.new("pr_metadata_invalid", e.message)
        end
        unless pr_head_oid
          raise Error.new(
            "pr_metadata_invalid",
            "pr.md is missing a valid full commit OID (#{allow_legacy_head_ref_oid ? 'head_oid/head_ref_oid' : 'head_oid'})"
          )
        end

        base_ref_name = pr_fm["base_ref_name"].to_s.strip
        if base_ref_name.empty?
          base_ref_name = nil
        else
          begin
            base_ref_name = Hive::GitRef.validate_branch_name(base_ref_name)
          rescue ArgumentError
            raise Error.new("pr_metadata_invalid", "pr.md base_ref_name is invalid")
          end
        end

        head_ref_name = pr_fm["head_ref_name"].to_s.strip
        if head_ref_name.empty?
          head_ref_name = nil
        else
          begin
            head_ref_name = Hive::GitRef.validate_branch_name(head_ref_name)
          rescue ArgumentError
            raise Error.new("pr_metadata_invalid", "pr.md head_ref_name is invalid")
          end
        end

        head_repository = pr_fm["head_repository"].to_s.strip.downcase
        if head_repository.empty?
          head_repository = nil
        else
          begin
            Hive::Gh::RepositoryIdentity.validated_repository_slug(head_repository)
          rescue Hive::GhError
            raise Error.new("pr_metadata_invalid", "pr.md head_repository is invalid")
          end
        end

        is_cross = if pr_fm.key?("is_cross_repository")
          value = pr_fm["is_cross_repository"]
          unless value == true || value == false
            raise Error.new("pr_metadata_invalid", "pr.md is_cross_repository must be boolean")
          end
          value
        else
          false
        end

        pr_state = pr_fm["state"].to_s.strip.upcase
        if pr_state.empty?
          pr_state = nil
        elsif !%w[OPEN CLOSED MERGED].include?(pr_state)
          raise Error.new("pr_metadata_invalid", "pr.md state #{pr_state.inspect} is invalid")
        end

        expected_root = Hive::Worktree.canonical_root(project_root, config: cfg)
        expected_worktree = worktree_path_for(project_root, slug, config: cfg)
        expected_branch = branch_for(pr_number)
        allow_local = if allow_local_transport.nil?
          cfg.is_a?(Hash) && cfg.dig("agent_git_gate", "allow_local_transport") == true
        else
          allow_local_transport == true
        end

        Resolved.new(
          task_folder: folder.freeze,
          project_root: project_root.freeze,
          project_name: project_name.freeze,
          task_id: task_id&.freeze,
          task_slug: slug.freeze,
          pr_number: pr_number,
          pr_url: parsed_url.fetch("url").freeze,
          pr_host: parsed_url.fetch("host").freeze,
          pr_repository: parsed_url.fetch("repository").freeze,
          base_ref_name: base_ref_name&.freeze,
          head_ref_name: head_ref_name&.freeze,
          head_repository: head_repository&.freeze,
          is_cross_repository: is_cross,
          pr_state: pr_state&.freeze,
          pr_head_oid: pr_head_oid.freeze,
          pr_head_oid_legacy: (!has_canonical && has_legacy),
          expected_root: expected_root.freeze,
          expected_worktree_path: expected_worktree.freeze,
          expected_branch: expected_branch.freeze,
          allow_local_transport: allow_local
        )
      end

      def validate_remote_identity!(identity, gate: Hive::AgentGitGate)
        urls = gate.remote_urls(
          repository_path: identity.project_root, remote: "origin", push: false
        )
        unless urls.one?
          raise Error.new(
            "remote_identity_invalid",
            "origin remote must resolve to exactly one fetch URL (found #{urls.size})"
          )
        end
        url = urls.first
        fingerprint = gate.remote_target_fingerprint(
          repository_path: identity.project_root,
          remote: "origin",
          push: false,
          allow_local_transport: identity.allow_local_transport
        )

        # Validate GitHub remote host/repository match whenever the URL is a
        # GitHub-shaped remote, and ALWAYS require one unless test-local
        # transport is explicitly enabled.
        github_shaped = url.match?(/\A(?:https?|ssh|git):\/\//i) ||
                        (url.match?(/\A(?:[^@\/]+@)?[^:\/]+:.+\z/) && !url.start_with?("/"))
        if !identity.allow_local_transport || github_shaped
          remote_id = begin
            Hive::Gh.repository_identity_from_remote(url)
          rescue Hive::GhError => e
            raise Error.new("remote_identity_invalid", e.message)
          end
          unless remote_id.fetch("host").downcase == identity.pr_host &&
                 remote_id.fetch("repository").downcase == identity.pr_repository
            raise Error.new(
              "remote_identity_invalid",
              "origin remote #{remote_id.fetch('host')}/#{remote_id.fetch('repository')} does not match " \
              "PR #{identity.pr_host}/#{identity.pr_repository}##{identity.pr_number}"
            )
          end
        end

        fingerprint
      rescue Hive::AgentGitGate::InvalidRequest => e
        if e.message.include?("executable Git helpers") || e.message.include?("could not be inspected safely")
          raise Error.new("git_config_unsafe", e.message)
        end
        raise Error.new("remote_identity_invalid", e.message)
      rescue Hive::AgentGitGate::Error => e
        raise Error.new("remote_identity_invalid", e.message)
      end

      def read_strict_frontmatter!(path, label:)
        bytes = read_bounded_regular!(path, max_bytes: PR_FILE_MAX_BYTES, label: label)
        match = bytes.match(Hive::Gh::FRONTMATTER_DELIMITER)
        unless match
          raise Error.new("pr_metadata_invalid", "#{label} is missing YAML frontmatter")
        end

        yaml_text = match[1]
        reject_duplicate_yaml_keys!(yaml_text, label: label)
        parsed = YAML.safe_load(yaml_text, permitted_classes: [], permitted_symbols: [], aliases: false)
        unless parsed.is_a?(Hash)
          raise Error.new("pr_metadata_invalid", "#{label} frontmatter must be a mapping")
        end

        parsed
      rescue Psych::Exception => e
        raise Error.new("pr_metadata_invalid", "#{label} frontmatter is invalid YAML: #{e.message}")
      end

      def read_bounded_regular!(path, max_bytes:, label:)
        stat = File.lstat(path)
        if stat.symlink?
          raise Error.new("pr_metadata_invalid", "#{label} must be a regular file, not a symlink")
        end
        unless stat.file?
          raise Error.new("pr_metadata_invalid", "#{label} must be a regular file")
        end

        File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
          opened = file.stat
          unless opened.file? && opened.dev == stat.dev && opened.ino == stat.ino
            raise Error.new("pr_metadata_invalid", "#{label} changed while opening")
          end
          content = file.read(max_bytes + 1) || ""
          if content.bytesize > max_bytes
            raise Error.new("pr_metadata_invalid", "#{label} exceeds #{max_bytes} bytes")
          end
          content
        end
      rescue Errno::ENOENT
        raise Error.new("pr_metadata_invalid", "#{label} is missing")
      rescue Errno::ELOOP
        raise Error.new("pr_metadata_invalid", "#{label} must be a regular file, not a symlink")
      rescue SystemCallError, IOError => e
        raise Error.new("pr_metadata_invalid", "#{label} could not be read (#{e.class})")
      end

      def validate_sibling_sidecars!(folder, expected_slug:, expected_url:)
        %w[task.md idea.md].each do |name|
          path = File.join(folder, name)
          next unless File.exist?(path) || File.symlink?(path)

          stat = File.lstat(path)
          if stat.symlink? || !stat.file?
            raise Error.new("sidecar_inconsistent", "#{name} must be a regular file")
          end
          bytes = read_bounded_regular!(path, max_bytes: PR_FILE_MAX_BYTES, label: name)
          match = bytes.match(Hive::Gh::FRONTMATTER_DELIMITER)
          next unless match

          reject_duplicate_yaml_keys!(match[1], label: name)
          fm = YAML.safe_load(match[1], permitted_classes: [], permitted_symbols: [], aliases: false)
          next unless fm.is_a?(Hash)

          if fm.key?("source") && !fm["source"].to_s.strip.empty? && !fm["source"].to_s.strip.casecmp?(SOURCE)
            raise Error.new("sidecar_inconsistent", "#{name} source contradicts internal PR review identity")
          end
          if fm.key?("slug") && !fm["slug"].to_s.strip.empty? && fm["slug"].to_s.strip != expected_slug
            raise Error.new("sidecar_inconsistent", "#{name} slug contradicts #{expected_slug}")
          end
          if name == "task.md" && fm.key?("pr_url") && !fm["pr_url"].to_s.strip.empty?
            parsed = Hive::Gh.parse_pull_request_url(fm["pr_url"])
            unless parsed && parsed.fetch("url") == expected_url
              raise Error.new("sidecar_inconsistent", "task.md pr_url contradicts pr.md pr_url")
            end
          end
        rescue Psych::Exception => e
          raise Error.new("sidecar_inconsistent", "#{name} frontmatter is invalid YAML: #{e.message}")
        end
      end
      private_class_method :validate_sibling_sidecars!

      def frontmatter_source_adhoc?(path)
        return false unless File.exist?(path) || File.symlink?(path)

        stat = File.lstat(path)
        return true if stat.symlink? # Let strict resolve! fail closed instead of ignoring.
        return false unless stat.file?

        bytes = File.open(path, File::RDONLY | File::NOFOLLOW) { |f| f.read(PR_FILE_MAX_BYTES) || "" }
        match = bytes.match(Hive::Gh::FRONTMATTER_DELIMITER)
        return false unless match

        fm = YAML.safe_load(match[1], permitted_classes: [], permitted_symbols: [], aliases: false)
        fm.is_a?(Hash) && fm["source"].to_s.strip.casecmp?(SOURCE)
      rescue Psych::Exception, SystemCallError, IOError
        false
      end
      private_class_method :frontmatter_source_adhoc?

      def reject_duplicate_yaml_keys!(yaml_text, label:)
        tree = Psych.parse(yaml_text)
        return unless tree

        check_mapping_duplicates!(tree, label: label)
      end
      private_class_method :reject_duplicate_yaml_keys!

      def check_mapping_duplicates!(node, label:)
        return unless node.respond_to?(:children) && node.children

        if node.is_a?(Psych::Nodes::Mapping)
          seen = {}
          node.children.each_slice(2) do |key_node, value_node|
            unless key_node.is_a?(Psych::Nodes::Scalar)
              raise Error.new("pr_metadata_invalid", "#{label} frontmatter keys must be scalars")
            end
            key = key_node.value.to_s
            if seen.key?(key)
              raise Error.new("pr_metadata_invalid", "#{label} frontmatter contains duplicate key #{key.inspect}")
            end
            seen[key] = true
            check_mapping_duplicates!(value_node, label: label)
          end
        else
          node.children.each { |child| check_mapping_duplicates!(child, label: label) }
        end
      end
      private_class_method :check_mapping_duplicates!

      def positive_pr_number!(value)
        number = Integer(value)
        raise ArgumentError, "PR number must be positive" unless number.positive?

        number
      end
      private_class_method :positive_pr_number!

      def validated_token!(value, label)
        token = value.to_s
        unless token.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/)
          raise ArgumentError, "#{label} is invalid"
        end
        token
      end
      private_class_method :validated_token!
    end
  end
end
