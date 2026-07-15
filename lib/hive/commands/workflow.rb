require "erb"
require "fileutils"
require "json"
require "pathname"
require "shellwords"
require "hive"
require "hive/config"
require "hive/git_ops"
require "hive/lock"
require "hive/workflows/descriptor_parser"
require "hive/workflows/loader"
require "hive/workflows/project"
require "hive/workflows/registry"
require "hive/honeycomb/installation"
require "hive/honeycomb/diff"
require "hive/honeycomb/package"
require "hive/honeycomb/registry"
require "hive/honeycomb/transaction"

module Hive
  module Commands
    class Workflow
      TEMPLATES_DIR = File.expand_path("../../../templates/workflows", __dir__)
      DEFAULT_TEMPLATE = "blank".freeze
      WORKFLOW_ID_RE = Hive::Workflows::DescriptorParser::SAFE_SLUG
      SCHEMA = "hive-workflow-new".freeze
      SCHEMAS = {
        "new" => SCHEMA,
        "install" => "hive-workflow-install",
        "list" => "hive-workflow-list",
        "update" => "hive-workflow-update",
        "remove" => "hive-workflow-remove"
      }.freeze
      SUBCOMMANDS = SCHEMAS.keys.freeze

      class UsageError < Hive::Error
        attr_reader :value, :expected

        # Closed set of usage-error shapes (which structured field each carries):
        #   missing subcommand        -> expected only
        #   unknown subcommand        -> value (the rejected verb) + expected
        #   bad/missing/reserved id / -> value (the rejected/colliding token) only
        #   scaffold collision
        def initialize(message, value: nil, expected: nil)
          super(message)
          @value = value
          @expected = expected
        end

        def exit_code
          Hive::ExitCodes::USAGE
        end
      end

      def self.new!(id, project_root: Dir.pwd, json: false, stdout: $stdout, template: DEFAULT_TEMPLATE)
        new("new", id, project_root: project_root, json: json, stdout: stdout, template: template).call!
      end

      def self.normalize_and_validate_id!(raw)
        id = normalize_id(raw)
        validate_id!(id)
        id
      end

      def self.scaffold_files!(id_raw, project_root:, template: DEFAULT_TEMPLATE)
        id = normalize_and_validate_id!(id_raw)
        template_dir = template_dir!(template)
        paths = scaffold_paths(id, project_root: project_root, template_dir: template_dir)
        refuse_overwrite!(paths)
        begin
          write_scaffold!(id, paths, template_dir)
          validate_descriptor!(paths.fetch(:descriptor))
          Hive::Workflows::Project.reset!
        rescue StandardError
          rollback_scaffold(paths)
          raise
        end
        { id: id, paths: paths }
      end

      # Inline-author pre-check for `hive init`: does scaffolding `id` clash with
      # files already on disk? A pure predicate — pass an id that
      # normalize_and_validate_id! has ALREADY accepted (the inline author
      # normalizes in prompt_new_workflow_id before calling this), so on a
      # pre-validated id it never raises and the `?` name holds. (It can still
      # raise on a corrupt project config — workflow_dir → Config.load →
      # ConfigError — but that is a real fault, not an id-shape rejection.) The
      # inline author always scaffolds from
      # the default (`blank`) template, so the pre-check resolves paths against
      # `blank` too. That is not truly template-independent — scaffold_collisions
      # also walks the template-dependent per-stage instruction files — but those
      # instructions all live under the `<id>/` dir this already checks, so the
      # descriptor + dir collision set a different template would produce is the
      # same.
      def self.scaffold_collision?(id, project_root:)
        paths = scaffold_paths(id, project_root: project_root, template_dir: template_dir!(DEFAULT_TEMPLATE))
        scaffold_collisions(paths).any?
      end

      # Sample templates ship as directories under `templates/workflows/` (the
      # bare `blank` stub plus richer multi-stage samples). A template dir holds
      # `descriptor.yml.erb` (rendered with the new id) and one `.md` instruction
      # per agent stage. Only dirs carrying a `descriptor.yml.erb` count, so a
      # stray file under the templates root is never offered as a template.
      def self.available_templates
        Dir.children(TEMPLATES_DIR).select do |name|
          File.file?(File.join(TEMPLATES_DIR, name, "descriptor.yml.erb"))
        end.sort
      end

      def self.template_dir!(template)
        name = template.to_s.strip
        name = DEFAULT_TEMPLATE if name.empty?
        dir = File.join(TEMPLATES_DIR, name)
        return dir if File.file?(File.join(dir, "descriptor.yml.erb"))

        raise UsageError.new(
          "unknown workflow template #{name.inspect} (available: #{available_templates.join(', ')})",
          value: name,
          expected: available_templates
        )
      end
      private_class_method :template_dir!

      # Shared scaffold-commit contract: hive init --new-workflow (fresh and
      # existing) and `hive workflow new` all commit a scaffolded descriptor
      # (plus, for init, the config.yml rebind) under the same
      # "workflows/<slug> created" message. Callers own the commit lock and the
      # pathspec relative-path mapping; this centralizes the stage/action
      # contract so the magic strings live in one place.
      def self.commit_workflow_scaffold(ops, slug:, pathspecs:)
        ops.hive_commit(stage_name: "workflows", slug: slug, action: "created", pathspecs: pathspecs)
      end

      # Filesystem-only rollback: unwinds the working-tree files write_scaffold!
      # created, NOT any git side-effects of a partially-run commit. hive_commit
      # stages by explicit pathspec, so a same-command retry re-stages exactly
      # these paths and refuse_overwrite! re-checks them — removing the files is
      # all a retry needs.
      #
      # NOTE: the shared-worktree callers commit into the long-lived
      # `.hive-state` worktree, where a failed commit ALSO leaves these pathspecs
      # STAGED. `hive init --new-workflow` on an existing project resets the index
      # for them (Init#reset_hive_state_index); `hive workflow new`'s own
      # commit_scaffold! (below) shares the SAME pre-existing exposure but
      # currently relies on this filesystem-only rollback alone — out of scope to
      # fix here, but `workflow new` is NOT index-safe just because init now is.
      # Either way this method intentionally leaves git untouched.
      # remove_scaffold_path tolerates
      # an already-absent target (like rm_f/rm_rf's force) and continues to the
      # next path on a fault, but CAPTURES the errno so warn_failed_scaffold_cleanup
      # can tell the operator WHY a leftover survived rather than emitting a bare
      # path list — a leftover would otherwise resurface as a confusing
      # refuse_overwrite! "already exists" on the next attempt.
      def self.rollback_scaffold(paths)
        reasons = {}
        remove_scaffold_path(paths.fetch(:descriptor), reasons)
        remove_scaffold_path(paths.fetch(:instruction_dir), reasons)
        warn_failed_scaffold_cleanup(paths, reasons)
      end

      # Remove one scaffold path, recording the underlying errno when a genuine
      # permission/busy fault keeps it on disk. The existence guard makes an
      # already-absent target a no-op (matching rm_f/rm_rf's force: true) without
      # swallowing the real fault the way the force variants do.
      def self.remove_scaffold_path(path, reasons)
        return unless File.exist?(path) || File.symlink?(path)

        FileUtils.remove_entry(path)
      rescue SystemCallError => e
        reasons[path] = e
      end
      private_class_method :remove_scaffold_path

      def self.normalize_id(value)
        id = value.to_s.strip
        return id unless id.empty?

        raise UsageError.new("missing workflow id", value: value)
      end
      private_class_method :normalize_id

      def self.validate_id!(id)
        unless WORKFLOW_ID_RE.match?(id)
          raise UsageError.new("invalid workflow id #{id.inspect} (must match #{WORKFLOW_ID_RE.source})", value: id)
        end
        return unless Hive::Workflows::Registry::WORKFLOWS.key?(id.to_sym)

        raise UsageError.new("workflow id #{id.inspect} is reserved by a built-in workflow", value: id)
      end
      private_class_method :validate_id!

      def self.scaffold_paths(id, project_root:, template_dir:)
        workflows_dir = workflow_dir(project_root)
        instruction_dir = File.join(workflows_dir, id)
        instructions = template_instruction_files(template_dir).map { |file| File.join(instruction_dir, file) }
        {
          descriptor: File.join(workflows_dir, "#{id}.yml"),
          instruction_dir: instruction_dir,
          instructions: instructions,
          # The primary instruction (first stage's). Keeps the `instruction_path`
          # JSON field single-valued for the strict hive-workflow-new schema; the
          # human output points at the dir when a template has several.
          instruction: instructions.first
        }
      end
      private_class_method :scaffold_paths

      # Sorted so the copy order — and the `instruction_path`/`next` the payload
      # reports — are deterministic across runs (golden-output tests).
      def self.template_instruction_files(template_dir)
        Dir.children(template_dir).select { |file| file.end_with?(".md") }.sort
      end
      private_class_method :template_instruction_files

      # Single source of "<hive_state_path>/workflows" — the scaffolder needs the
      # raw config error to surface (no fallback), which Loader.workflow_dir
      # provides; Project#workflow_dir_for is the fallback-wrapping variant.
      def self.workflow_dir(project_root)
        Hive::Workflows::Loader.workflow_dir(project_root)
      end
      private_class_method :workflow_dir

      def self.refuse_overwrite!(paths)
        collisions = scaffold_collisions(paths)
        return if collisions.empty?

        raise UsageError.new("workflow scaffold already exists at #{collisions.join(', ')}", value: collisions.first)
      end
      private_class_method :refuse_overwrite!

      # One source of truth for "what would this scaffold overwrite?" — shared by
      # refuse_overwrite! (the scaffold_files! guard) and scaffold_collision?
      # (init's inline-author pre-check). Checks the descriptor, the instruction
      # dir, and every per-stage instruction file the template would write.
      def self.scaffold_collisions(paths)
        ([ paths.fetch(:descriptor), paths.fetch(:instruction_dir) ] + paths.fetch(:instructions)).select do |path|
          File.exist?(path)
        end
      end
      private_class_method :scaffold_collisions

      def self.write_scaffold!(id, paths, template_dir)
        FileUtils.mkdir_p(paths.fetch(:instruction_dir))
        File.write(paths.fetch(:descriptor), render_descriptor(id, template_dir))
        template_instruction_files(template_dir).each do |file|
          File.write(File.join(paths.fetch(:instruction_dir), file), File.read(File.join(template_dir, file)))
        end
      end
      private_class_method :write_scaffold!

      def self.render_descriptor(id, template_dir)
        template = File.read(File.join(template_dir, "descriptor.yml.erb"))
        ERB.new(template, trim_mode: "-").result_with_hash(id: id)
      end
      private_class_method :render_descriptor

      def self.validate_descriptor!(path)
        Hive::Workflows::DescriptorParser.parse_file(path)
      end
      private_class_method :validate_descriptor!

      # Localizes the signal when a permission/busy failure leaves the scaffold
      # on disk, where it would otherwise resurface as a confusing
      # refuse_overwrite! "already exists" on the next attempt. `reasons` carries
      # the errno remove_scaffold_path captured per leftover so the operator
      # learns WHY cleanup failed (e.g. EACCES on a read-only parent) instead of
      # a bare path list.
      def self.warn_failed_scaffold_cleanup(paths, reasons = {})
        leftovers = [ paths.fetch(:descriptor), paths.fetch(:instruction_dir) ].select { |path| File.exist?(path) }
        return if leftovers.empty?

        described = leftovers.map do |path|
          reason = reasons[path]
          reason ? "#{path} (#{reason.class}: #{reason.message})" : path
        end
        warn "hive workflow: scaffold cleanup could not remove #{described.join(', ')}; " \
             "remove them manually before retrying --new-workflow"
      rescue Errno::EPIPE
        nil
      end
      private_class_method :warn_failed_scaffold_cleanup

      def initialize(
        subcommand,
        id = nil,
        project_root: Dir.pwd,
        json: false,
        stdout: $stdout,
        stdin: $stdin,
        template: nil,
        yes: false,
        force: false,
        remote: false,
        outdated: false,
        all: false,
        registry: nil,
        package_verifier: nil,
        transaction: nil,
        catalog_path: Hive::Paths.honeycomb_catalog_path
      )
        @subcommand = subcommand
        @id = id
        @project_root = File.expand_path(project_root)
        @json = json
        @stdout = stdout
        @stdin = stdin
        @template = template
        @yes = yes
        @force = force
        @remote = remote
        @outdated = outdated
        @all = all
        @registry = registry
        @package_verifier = package_verifier
        @transaction = transaction
        @catalog_path = catalog_path
        @preview_payload = nil
      end

      def call
        call!
      rescue Hive::Error, SystemCallError, IOError => e
        # ConcurrentRunError (commit-lock contention, TEMPFAIL/75) is now caught
        # too: previously it escaped to bin/hive as plain stderr, hiding the
        # retryable-vs-terminal distinction from --json agent callers.
        # SystemCallError/IOError are caught for the same reason: a disk-write
        # fault from write_scaffold!'s mkdir_p/File.write would otherwise escape
        # past `call` to bin/hive (which only handles Errno::EPIPE/Thor::Error/
        # Hive::Error), yielding a raw backtrace instead of the schema'd --json
        # envelope. error_kind_for's else→ERROR arm classifies them.
        if @json
          @stdout.puts JSON.generate(error_payload(e))
        else
          warn "hive workflow: #{e.message}"
        end
        # SystemCallError/IOError carry no #exit_code; map them to GENERIC the
        # same way ErrorEnvelope.build does for the --json exit_code field.
        exit(e.respond_to?(:exit_code) ? e.exit_code : Hive::ExitCodes::GENERIC)
      end

      def call!
        expected_list = SUBCOMMANDS.join(", ")
        if @subcommand.nil?
          raise UsageError.new(
            "missing SUBCOMMAND (expected: #{expected_list})",
            expected: SUBCOMMANDS
          )
        end

        unless SUBCOMMANDS.include?(@subcommand)
          raise UsageError.new(
            "unknown workflow subcommand #{@subcommand.inspect} (expected: #{expected_list})",
            value: @subcommand,
            expected: SUBCOMMANDS
          )
        end

        validate_subcommand_options!
        case @subcommand
        when "new" then call_new!
        when "install" then call_install!
        when "list" then call_list!
        when "update" then call_update!
        when "remove" then call_remove!
        end
      end

      private

      def call_new!
        scaffold = self.class.scaffold_files!(@id, project_root: @project_root, template: @template)
        id = scaffold.fetch(:id)
        paths = scaffold.fetch(:paths)
        begin
          # commit_scaffold! is INSIDE the rollback protection: a commit failure
          # (GitError / ConcurrentRunError) would otherwise leave orphan
          # descriptor + instruction files on disk that make the next retry fail
          # in refuse_overwrite!, turning a retryable command into a stuck one.
          commit_scaffold!(id, paths)
        rescue StandardError
          self.class.rollback_scaffold(paths)
          raise
        end

        payload = success_payload(id, paths)
        if @json
          @stdout.puts JSON.generate(payload)
        else
          @stdout.puts "hive: created workflow #{id} at #{paths.fetch(:descriptor)}"
          if paths.fetch(:instructions).size > 1
            @stdout.puts "edit: #{paths.fetch(:instruction_dir)}/ (#{paths.fetch(:instructions).size} stage instructions to fill in)"
          else
            @stdout.puts "edit: #{paths.fetch(:instruction)} (the `work` stage instruction — a placeholder until you define it)"
          end
          @stdout.puts "next: #{payload.fetch("next")}"
        end
        payload
      end

      def call_install!
        pin = registry.resolve(@id, refresh: true)
        package = package_verifier.verify(pin, staging_parent: workflows_dir)
        collision = install_collision(package.pin.name)
        @preview_payload = install_preview(package, collision)
        render_install_preview(@preview_payload) unless @json
        if collision.fetch("blocked")
          raise Hive::Honeycomb::CollisionError, collision.fetch("message")
        end
        approval!("Install honeycomb/#{package.pin.name}")
        result = transaction.apply(installs: [ package ], force: @force, action: "installed")
        payload = {
          "schema" => SCHEMAS.fetch("install"), "schema_version" => 1, "ok" => true,
          "changed" => result.changed, "name" => package.pin.name, "source" => package.pin.source,
          "version" => package.pin.version, "sha" => package.pin.sha, "files" => package.files.keys.sort,
          "preview" => @preview_payload
        }
        emit_success(payload)
      ensure
        FileUtils.rm_rf(package.staging_dir) if package&.staging_dir && File.exist?(package.staging_dir)
      end

      def call_list!
        entries = honeycomb_lockfile.read
        rows = if @remote
          remote_rows(registry.refresh!)
        elsif @outdated
          catalog = registry.refresh!
          local_rows(entries, catalog: catalog).select { |row| row.fetch("update_available") == true }
        else
          local_rows(entries, catalog: cached_catalog)
        end
        payload = {
          "schema" => SCHEMAS.fetch("list"), "schema_version" => 1, "ok" => true,
          "mode" => @remote ? "remote" : (@outdated ? "outdated" : "local"),
          "workflows" => rows
        }
        unless @json
          @stdout.puts "NAME\tVERSION\tSHA\tSOURCE\tUPDATE\tINTEGRITY\tPERMISSIONS"
          rows.each do |row|
            update = row["update_available"].nil? ? "unknown" : row["update_available"].to_s
            @stdout.puts [ row["name"], row["version"] || "unknown", row["sha"], row["source"], update,
                           row["integrity"] || "remote", row["permissions"] || "-" ].join("\t")
          end
        end
        emit_success(payload)
      end

      def call_update!
        entries = honeycomb_lockfile.read
        candidates, noops = resolve_update_candidates(entries)
        packages = []
        previews = []
        candidates.each do |candidate|
          entry = candidate.fetch(:entry)
          pin = candidate.fetch(:pin)
          package = package_verifier.verify(pin, staging_parent: workflows_dir)
          packages << package
          inspection = Hive::Honeycomb::Installation.new(workflows_dir).inspect(entry)
          diff = Hive::Honeycomb::Diff.build(
            entry: entry, package: package, installed_root: File.join(workflows_dir, entry.name)
          )
          preview = update_preview(entry, package, diff, inspection.state, explicit: candidate.fetch(:explicit))
          previews << preview
        end
        @preview_payload = { "operation" => "update", "updates" => previews, "noops" => noops }
        render_update_preview(@preview_payload) unless @json
        blocked = previews.find { |preview| preview.fetch("ownership") != "clean" && !@force }
        if blocked
          raise Hive::Honeycomb::CollisionError,
                "managed workflow #{blocked.fetch('name').inspect} is #{blocked.fetch('ownership')}; use --force to update it"
        end
        if packages.empty?
          return emit_success(
            "schema" => SCHEMAS.fetch("update"), "schema_version" => 1, "ok" => true,
            "changed" => false, "updates" => [], "noops" => noops, "preview" => @preview_payload
          )
        end
        approval!("Update #{packages.map { |package| package.pin.name }.join(', ')}")
        result = transaction.apply(installs: packages, force: @force, action: "updated")
        emit_success(
          "schema" => SCHEMAS.fetch("update"), "schema_version" => 1, "ok" => true,
          "changed" => result.changed, "updates" => previews, "noops" => noops, "preview" => @preview_payload
        )
      ensure
        packages&.each do |package|
          FileUtils.rm_rf(package.staging_dir) if File.exist?(package.staging_dir)
        end
      end

      def call_remove!
        name = normalize_managed_name(@id, allow_selector: false)
        lock_error = nil
        entries = begin
          honeycomb_lockfile.read
        rescue Hive::Honeycomb::LockfileError => e
          lock_error = e
          {}
        end
        entry = entries[name]
        installation = Hive::Honeycomb::Installation.new(workflows_dir)
        inspection = entry ? installation.inspect(entry) : nil
        state = lock_error ? "unknown" : (inspection&.state || "unmanaged")
        @preview_payload = {
          "operation" => "remove", "name" => name, "ownership" => state,
          "lock_integrity" => lock_error ? "invalid" : (entry ? "known" : "missing"),
          "paths" => [ File.join(workflows_dir, name) ]
        }
        render_remove_preview(@preview_payload) unless @json
        if entry && !inspection.clean? && !@force
          raise Hive::Honeycomb::CollisionError,
                "managed workflow #{name.inspect} is #{inspection.state}; use --force to remove it"
        end
        unless entry
          unless @force && installation.canonical_managed_root?(name)
            raise Hive::Honeycomb::CollisionError,
                  "ownership for workflow #{name.inspect} cannot be proven; use --force for best-effort cleanup"
          end
        end
        approval!("Remove honeycomb/#{name}")
        result = transaction.apply(
          removals: [ name ], force: @force, allow_unknown_removals: !entry || !lock_error.nil?, action: "removed"
        )
        if result.partial
          raise Hive::Honeycomb::PartialRemovalError,
                "best-effort removal of honeycomb/#{name} completed, but lock integrity was missing or stale"
        end
        emit_success(
          "schema" => SCHEMAS.fetch("remove"), "schema_version" => 1, "ok" => true,
          "changed" => result.changed, "partial" => false, "name" => name, "preview" => @preview_payload
        )
      end

      def resolve_update_candidates(entries)
        requested = if @all
          registry.refresh!
          entries.keys.sort
        else
          [ normalize_managed_name(@id, allow_selector: true) ]
        end
        candidates = []
        noops = []
        requested.each do |name|
          entry = entries[name]
          raise Hive::Honeycomb::ResolutionError, "workflow #{name.inspect} is not installed" unless entry
          explicit = !@all && @id.to_s.include?("@")
          if !explicit && %w[sha digest].include?(entry.selector_kind)
            noops << { "name" => name, "reason" => "pinned", "sha" => entry.sha }
            next
          end
          raw_reference = if explicit
            @id.start_with?("honeycomb/") ? @id : "honeycomb/#{@id}"
          else
            "honeycomb/#{name}"
          end
          pin = registry.resolve(raw_reference, refresh: !@all)
          if pin.sha == entry.sha
            noops << { "name" => name, "reason" => "up_to_date", "sha" => entry.sha }
            next
          end
          if comparable_downgrade?(entry, pin) && !explicit
            raise Hive::Honeycomb::ResolutionError,
                  "update for #{name.inspect} would downgrade #{entry.version} to #{pin.version}; select it explicitly"
          end
          candidates << { entry: entry, pin: pin, explicit: explicit }
        end
        [ candidates, noops ]
      end

      def normalize_managed_name(raw, allow_selector:)
        value = raw.to_s
        reference = Hive::Honeycomb::Reference.parse(value.start_with?("honeycomb/") ? value : "honeycomb/#{value}")
        if reference.selector && !allow_selector
          raise UsageError.new("workflow #{@subcommand} does not accept a selector", value: raw)
        end
        reference.name
      end

      def comparable_downgrade?(entry, pin)
        entry.version && pin.version && Gem::Version.new(pin.version) < Gem::Version.new(entry.version)
      end

      def update_preview(entry, package, diff, ownership, explicit:)
        {
          "name" => entry.name,
          "from_version" => entry.version,
          "to_version" => package.pin.version,
          "from_sha" => entry.sha,
          "to_sha" => package.pin.sha,
          "explicit" => explicit,
          "downgrade" => comparable_downgrade?(entry, package.pin),
          "ownership" => ownership,
          "permission_changes" => diff.permissions,
          "permission_escalation" => diff.escalation,
          "instruction_diffs" => diff.instruction_diffs,
          "descriptor_changed" => diff.descriptor_changed,
          "asset_changes" => diff.asset_changes,
          "metadata_only" => diff.metadata_only
        }
      end

      def render_update_preview(preview)
        preview.fetch("noops").each do |noop|
          @stdout.puts "#{noop.fetch('name')}: #{noop.fetch('reason')} (#{noop.fetch('sha')})"
        end
        preview.fetch("updates").each do |update|
          @stdout.puts "Update honeycomb/#{update.fetch('name')}"
          @stdout.puts "version: #{update.fetch('from_version') || 'unknown'} -> " \
                       "#{update.fetch('to_version') || 'unknown'}#{update.fetch('downgrade') ? ' (DOWNGRADE)' : ''}"
          @stdout.puts "sha: #{update.fetch('from_sha')} -> #{update.fetch('to_sha')}"
          @stdout.puts "ownership: #{update.fetch('ownership')}"
          @stdout.puts "PERMISSION ESCALATION" if update.fetch("permission_escalation")
          update.fetch("permission_changes").each do |field, change|
            if change.key?("added")
              @stdout.puts "permissions #{field}: +#{change.fetch('added').join(',')} " \
                           "-#{change.fetch('removed').join(',')}"
            elsif change.fetch("before") != change.fetch("after")
              @stdout.puts "permissions #{field}: #{change.fetch('before')} -> #{change.fetch('after')}"
            end
          end
          update.fetch("instruction_diffs").sort.each { |_path, text| @stdout.print(text) }
          @stdout.puts "descriptor changed: #{update.fetch('descriptor_changed')}"
          assets = update.fetch("asset_changes")
          @stdout.puts "assets added=#{assets.fetch('added').join(',')} removed=#{assets.fetch('removed').join(',')} " \
                       "changed=#{assets.fetch('changed').join(',')}"
        end
      end

      def render_remove_preview(preview)
        @stdout.puts "Remove honeycomb/#{preview.fetch('name')}"
        @stdout.puts "ownership: #{preview.fetch('ownership')}"
        @stdout.puts "lock integrity: #{preview.fetch('lock_integrity')}"
        @stdout.puts "paths: #{preview.fetch('paths').join(', ')}"
      end

      def validate_subcommand_options!
        case @subcommand
        when "new"
          reject_flags!(yes: @yes, force: @force, remote: @remote, outdated: @outdated, all: @all)
        when "install"
          require_argument!("honeycomb reference")
          reject_flags!(template: !@template.nil?, remote: @remote, outdated: @outdated, all: @all)
        when "list"
          raise UsageError.new("workflow list does not accept a reference", value: @id) if @id
          raise UsageError, "workflow list: --remote and --outdated are mutually exclusive" if @remote && @outdated
          reject_flags!(template: !@template.nil?, yes: @yes, force: @force, all: @all)
        when "update"
          reject_flags!(template: !@template.nil?, remote: @remote, outdated: @outdated)
          if @all == !@id.nil?
            raise UsageError, "workflow update requires either NAME[@selector] or --all"
          end
        when "remove"
          require_argument!("managed workflow name")
          reject_flags!(template: !@template.nil?, remote: @remote, outdated: @outdated, all: @all)
        end
      end

      def reject_flags!(flags)
        invalid = flags.select { |_name, active| active }.keys
        return if invalid.empty?
        raise UsageError, "workflow #{@subcommand}: invalid option(s) #{invalid.map { |name| "--#{name}" }.join(', ')}"
      end

      def require_argument!(label)
        return unless @id.nil? || @id.to_s.strip.empty?
        raise UsageError, "workflow #{@subcommand}: missing #{label}"
      end

      def registry
        @registry ||= Hive::Honeycomb::Registry.new
      end

      def package_verifier
        @package_verifier ||= Hive::Honeycomb::Package.new(registry: registry)
      end

      def transaction
        @transaction ||= Hive::Honeycomb::Transaction.new(project_root: @project_root)
      end

      def workflows_dir
        @workflows_dir ||= Hive::Workflows::Loader.workflow_dir(@project_root)
      end

      def honeycomb_lockfile
        @honeycomb_lockfile ||= Hive::Honeycomb::Lockfile.new(File.join(workflows_dir, ".honeycomb.lock"))
      end

      def install_collision(name)
        if Hive::Workflows::Registry::WORKFLOWS.key?(name.to_sym)
          return { "state" => "reserved", "blocked" => true,
                   "message" => "workflow id #{name.inspect} is reserved by a built-in workflow" }
        end
        entries = honeycomb_lockfile.read
        installation = Hive::Honeycomb::Installation.new(workflows_dir)
        if (entry = entries[name])
          state = installation.inspect(entry).state
          blocked = state != "clean" && !@force
          { "state" => state, "blocked" => blocked,
            "message" => "managed workflow #{name.inspect} is #{state}; use --force to replace it" }
        else
          paths = installation.unmanaged_collisions(name)
          blocked = paths.any? && !@force
          { "state" => paths.empty? ? "none" : "unmanaged", "blocked" => blocked, "paths" => paths,
            "message" => "unmanaged workflow collision at #{paths.join(', ')}; use --force to replace it" }
        end
      end

      def install_preview(package, collision)
        {
          "operation" => "install", "name" => package.pin.name, "source" => package.pin.source,
          "version" => package.pin.version, "sha" => package.pin.sha, "digest" => package.pin.digest,
          "files" => package.files.keys.sort, "security" => package.security_report.summary,
          "findings" => package.security_report.findings, "collision" => collision
        }
      end

      def render_install_preview(preview)
        @stdout.puts "Install honeycomb/#{preview.fetch('name')}"
        @stdout.puts "source: #{preview.fetch('source')}"
        @stdout.puts "version: #{preview.fetch('version') || 'unknown'}"
        @stdout.puts "immutable sha: #{preview.fetch('sha')}"
        @stdout.puts "files: #{preview.fetch('files').join(', ')}"
        summary = preview.fetch("security")
        @stdout.puts "permissions: #{summary.fetch('presets').join(', ')}"
        @stdout.puts "tools: #{summary.fetch('tools').empty? ? 'none' : summary.fetch('tools').join(', ')}"
        @stdout.puts "dirs: #{summary.fetch('dirs').empty? ? 'none' : summary.fetch('dirs').join(', ')}"
        @stdout.puts "shell-capable: #{summary.fetch('shell_capable') ? 'yes' : 'no'}"
        preview.fetch("findings").each do |finding|
          @stdout.puts "instruction: #{finding.fetch('path')}:#{finding.fetch('line')} " \
                       "#{finding.fetch('kind')} risks=#{finding.fetch('high_risk').join(',')}"
        end
        collision = preview.fetch("collision")
        @stdout.puts "collision: #{collision.fetch('state')}"
      end

      def approval!(label)
        return true if @yes
        unless @stdin.respond_to?(:tty?) && @stdin.tty?
          raise Hive::Honeycomb::ApprovalError,
                "#{label} requires --yes in non-interactive mode; no changes were made"
        end
        @stdout.print "Proceed? [y/N] "
        @stdout.flush
        answer = @stdin.gets.to_s.strip.downcase
        return true if %w[y yes].include?(answer)
        raise Hive::Honeycomb::ApprovalError, "#{label} cancelled; no changes were made"
      end

      def local_rows(entries, catalog:)
        installation = Hive::Honeycomb::Installation.new(workflows_dir)
        entries.keys.sort.map do |name|
          entry = entries.fetch(name)
          latest = begin
            catalog&.latest_for(name)
          rescue Hive::Honeycomb::ResolutionError
            nil
          end
          update = if entry.selector_kind == "sha"
            false
          elsif latest
            latest.sha != entry.sha
          end
          {
            "name" => name, "version" => entry.version, "sha" => entry.sha, "source" => entry.source,
            "update_available" => update, "integrity" => installation.inspect(entry).state,
            "permissions" => entry.permissions_pointer
          }
        end
      end

      def remote_rows(catalog)
        catalog.workflow_names.sort.map do |name|
          release = catalog.latest_for(name)
          { "name" => name, "version" => release.version, "sha" => release.sha, "source" => Hive::Honeycomb::SOURCE,
            "update_available" => nil, "integrity" => nil, "permissions" => nil }
        end
      end

      def cached_catalog
        return nil unless File.file?(@catalog_path)
        Hive::Honeycomb::Catalog.load(File.binread(@catalog_path))
      rescue Hive::Honeycomb::CatalogError, SystemCallError, IOError
        nil
      end

      def emit_success(payload)
        @stdout.puts JSON.generate(payload) if @json
        payload
      end

      def commit_scaffold!(id, paths)
        ops = Hive::GitOps.new(@project_root)
        Hive::Lock.with_commit_lock(hive_state_path) do
          self.class.commit_workflow_scaffold(ops, slug: id, pathspecs: [
            relative_to_workflows_root(paths.fetch(:descriptor)),
            relative_to_workflows_root(paths.fetch(:instruction_dir))
          ])
        end
      end

      def relative_to_workflows_root(path)
        Pathname.new(path).relative_path_from(Pathname.new(hive_state_path)).to_s
      end

      def hive_state_path
        @hive_state_path ||= File.expand_path(Hive::Config.load(@project_root).fetch("hive_state_path"), @project_root)
      end

      def success_payload(id, paths)
        {
          "schema" => SCHEMA,
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
          "ok" => true,
          "id" => id,
          "descriptor_path" => paths.fetch(:descriptor),
          "instruction_path" => paths.fetch(:instruction),
          "next" => "hive new #{Shellwords.escape(File.basename(@project_root))} --workflow #{id} \"<your idea>\""
        }
      end

      # Route through the gem-wide ErrorEnvelope so the payload carries the same
      # schema / schema_version / error_kind keys as every other hive-* command
      # (agents branch on those uniformly).
      def error_payload(error)
        Hive::Schemas::ErrorEnvelope.build(
          schema: envelope_schema,
          error: error,
          error_kind: error_kind_for(error),
          extras: error_extras(error)
        )
      end

      # Surface command-specific UsageError details through structured extras so
      # agents do not need to regex `message`. Passed through the local seam to
      # avoid changing the gem-wide ErrorEnvelope.build.
      def error_extras(error)
        extras = {}
        extras["value"] = error.value if error.respond_to?(:value) && !error.value.nil?
        extras["expected"] = error.expected if error.respond_to?(:expected) && !error.expected.nil?
        extras["preview"] = @preview_payload if @preview_payload

        extras
      end

      def envelope_schema
        SCHEMAS.fetch(@subcommand, SCHEMA)
      end

      def error_kind_for(error)
        return workflow_new_error_kind(error) if @subcommand.nil? || @subcommand == "new" || !SUBCOMMANDS.include?(@subcommand)

        kinds = Hive::Schemas::WorkflowHoneycombErrorKind
        case error
        when UsageError                              then kinds::USAGE
        when Hive::Honeycomb::ApprovalError          then kinds::APPROVAL
        when Hive::Honeycomb::CollisionError         then kinds::COLLISION
        when Hive::Honeycomb::PartialRemovalError    then kinds::PARTIAL
        when Hive::Honeycomb::RegistryError          then kinds::NETWORK
        when Hive::Honeycomb::IntegrityError,
             Hive::Honeycomb::ManifestError,
             Hive::Honeycomb::LockfileError          then kinds::INTEGRITY
        when Hive::ConcurrentRunError                then kinds::CONCURRENT_RUN
        when Hive::GitError                          then kinds::GIT
        when Hive::ConfigError                       then kinds::CONFIG
        else                                              kinds::ERROR
        end
      end

      def workflow_new_error_kind(error)
        kinds = Hive::Schemas::WorkflowNewErrorKind
        case error
        when UsageError               then kinds::USAGE
        when Hive::ConcurrentRunError then kinds::CONCURRENT_RUN
        when Hive::GitError           then kinds::GIT
        when Hive::ConfigError        then kinds::CONFIG
        else                               kinds::ERROR
        end
      end
    end
  end
end
