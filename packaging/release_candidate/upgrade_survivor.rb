# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "open3"
require "yaml"
require_relative "baseline_catalog"
require_relative "installed_target"
require_relative "invariant_snapshot"
require_relative "process_teardown"

module HiveReleaseCandidate
  class ChannelPrefixOracle
    CHANNELS = {
      "linux-x86_64" => "linux-bash",
      "linux-arm64" => "linux-bash",
      "macos-arm64" => "homebrew-local-formula"
    }.freeze

    def verify(prefix:, platform:, candidate_target:)
      channel = CHANNELS.fetch(platform) do
        raise UsageError, "unsupported channel-faithful platform #{platform.inspect}"
      end
      root = safe_directory!(prefix)
      manifest_path = File.join(root, ".hive-install.json")
      manifest = JSON.parse(File.binread(manifest_path))
      required = %w[
        candidate_gem_sha256 channel dependencies_current files platform
        sidecars_current stale_files wrapper_role
      ]
      unless manifest.is_a?(Hash) && manifest.keys.sort == required &&
             manifest["platform"] == platform && manifest["channel"] == channel
        raise Error, "channel install manifest is invalid"
      end
      expected_digest = candidate_target.manifest.fetch("gem_sha256")
      raise Error, "channel candidate digest mismatch" unless manifest["candidate_gem_sha256"] == expected_digest
      raise Error, "channel wrapper does not resolve candidate bytes" unless manifest["wrapper_role"] == "candidate"
      unless manifest["sidecars_current"] == true && manifest["dependencies_current"] == true
        raise Error, "channel sidecars or dependencies are stale"
      end
      unless manifest["stale_files"] == []
        raise Error, "stale channel files remain: #{manifest['stale_files'].join(', ')}"
      end

      files = manifest["files"]
      unless files.is_a?(Hash) && files.key?("bin/hive")
        raise Error, "channel manifest must bind the installed wrapper"
      end
      actual = inventory(root, excluding: [ ".hive-install.json" ])
      raise Error, "channel prefix contains stale or substituted files" unless actual == files

      manifest.merge("status" => "passed")
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError => e
      raise Error, "channel prefix is invalid: #{e.message}"
    end

    private

    def safe_directory!(value)
      path = File.expand_path(value)
      stat = File.lstat(path)
      unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
        raise Error, "channel prefix must be an owned directory"
      end
      path
    end

    def inventory(root, excluding:)
      paths = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
        next if [ ".", ".." ].include?(File.basename(path))
        relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
        next if excluding.include?(relative)
        stat = File.lstat(path)
        raise Error, "channel prefix contains a symlink" if stat.symlink?
        next if stat.directory?
        raise Error, "channel prefix contains a non-regular file" unless stat.file? && stat.uid == Process.uid
        [ relative, { "size" => stat.size, "sha256" => Digest::SHA256.file(path).hexdigest } ]
      end
      paths.to_h
    end
  end

  class UpgradeSurvivor
    class ReviewedChannelUpdater
      SIDECARS = {
        "linux-bash" => %w[hive/install-channel hive/install-prefix],
        "homebrew-local-formula" => %w[share/hive/install-channel]
      }.freeze

      def apply!(prefix:, candidate_target:, run_root:, channel:)
        unless ChannelPrefixOracle::CHANNELS.value?(channel)
          raise UsageError, "unreviewed candidate channel update seam #{channel.inspect}"
        end
        retired = File.join(run_root, "channel-baseline-applied")
        receipt = File.join(run_root, "channel-update-receipt")
        [ retired, receipt ].each do |path|
          raise Error, "channel update path already exists: #{path}" if File.exist?(path) || File.symlink?(path)
        end
        prepare_channel_marker(prefix, channel)
        shim = File.expand_path(
          channel == "linux-bash" ? "channel_shims/linux" : "channel_shims/macos",
          __dir__
        )
        environment = candidate_target.environment.merge(
          "PATH" => [ shim, candidate_target.environment.fetch("PATH") ].join(File::PATH_SEPARATOR),
          "HIVE_PREFIX" => prefix,
          "HOMEBREW_PREFIX" => prefix,
          "HIVE_RC_CHANNEL" => channel,
          "HIVE_RC_CHANNEL_PREFIX" => prefix,
          "HIVE_RC_CHANNEL_CANDIDATE_ROOT" => candidate_target.root,
          "HIVE_RC_CHANNEL_RUN_ROOT" => run_root,
          "HIVE_RC_CHANNEL_RECEIPT" => receipt,
          "HIVE_RC_CONTROL_ROOT" => File.expand_path(__dir__)
        )
        stdout, stderr, status = Open3.capture3(
          environment, candidate_target.executable, "update", chdir: run_root
        )
        unless status.success?
          raise Error, "channel update seam failed: #{stderr.strip}"
        end
        applied = File.binread(receipt).strip
        raise Error, "channel update receipt mismatch" unless applied == channel

        {
          "seam" => channel == "linux-bash" ?
            "linux-bash-hive-update" :
            "macos-homebrew-local-formula-hive-update",
          "retired_baseline_prefix" => retired,
          "stdout" => stdout,
          "stderr" => stderr
        }
      end

      private

      def prepare_channel_marker(prefix, channel)
        paths = SIDECARS.fetch(channel)
        paths.each { |path| FileUtils.mkdir_p(File.dirname(File.join(prefix, path))) }
        if channel == "linux-bash"
          File.write(File.join(prefix, paths.fetch(0)), "bash\n")
          File.write(File.join(prefix, paths.fetch(1)), "#{prefix}\n")
        else
          File.write(File.join(prefix, paths.fetch(0)), "brew\n")
          brew = File.join(prefix, "bin", "brew")
          FileUtils.mkdir_p(File.dirname(brew))
          FileUtils.cp(File.expand_path("channel_shims/macos/brew", __dir__), brew)
          FileUtils.chmod(0o755, brew)
        end
      end
    end

    class FixedChannelExecutor
      def initialize(targets:, updater: nil)
        @baseline = targets.fetch("baseline")
        @candidate = targets.fetch("candidate")
        @updater = updater || ReviewedChannelUpdater.new
      end

      def call(platform:, run_root:, **)
        prefix = File.join(run_root, "channel-prefix")
        raise Error, "channel prefix already exists" if File.exist?(prefix) || File.symlink?(prefix)

        verify_source!(@baseline.root)
        verify_source!(@candidate.root)
        baseline_clone = File.join(run_root, "channel-baseline-prefix")
        raise Error, "baseline clone already exists" if File.exist?(baseline_clone) || File.symlink?(baseline_clone)
        FileUtils.mkdir_p(baseline_clone)
        FileUtils.cp_r(File.join(@baseline.root, "."), baseline_clone, preserve: true)
        FileUtils.mkdir_p(prefix)
        FileUtils.cp_r(File.join(baseline_clone, "."), prefix, preserve: true)
        baseline_files = inventory(prefix)
        baseline_digest = digest_inventory(baseline_files)
        channel = ChannelPrefixOracle::CHANNELS.fetch(platform)
        update = @updater.apply!(
          prefix: prefix, candidate_target: @candidate,
          run_root: run_root, channel: channel
        )
        files = inventory(prefix)
        candidate_files = inventory(@candidate.root)
        sidecars = ReviewedChannelUpdater::SIDECARS.fetch(channel)
        compared_files = files.reject { |path, _row| sidecars.include?(path) }
        stale_files = (compared_files.keys - candidate_files.keys).sort
        dependencies_current = stale_files.empty? &&
          candidate_files.all? { |path, row| compared_files[path] == row }
        wrapper_role = files["bin/hive"] == candidate_files["bin/hive"] ?
          "candidate" : "unknown"
        expected_sidecars = channel == "linux-bash" ?
          { sidecars.fetch(0) => "bash\n", sidecars.fetch(1) => "#{prefix}\n" } :
          { sidecars.fetch(0) => "brew\n" }
        sidecars_current = expected_sidecars.all? do |path, content|
          File.binread(File.join(prefix, path)) == content
        rescue Errno::ENOENT
          false
        end
        manifest = {
          "platform" => platform,
          "channel" => channel,
          "candidate_gem_sha256" => @candidate.manifest.fetch("gem_sha256"),
          "wrapper_role" => wrapper_role,
          "sidecars_current" => sidecars_current,
          "dependencies_current" => dependencies_current,
          "stale_files" => stale_files,
          "files" => files
        }
        File.write(File.join(prefix, ".hive-install.json"), JSON.generate(manifest))
        ChannelPrefixOracle.new.verify(
          prefix: prefix, platform: platform, candidate_target: @candidate
        ).merge(
          "baseline_prefix_sha256" => baseline_digest,
          "baseline_prefix_files" => baseline_files,
          "baseline_clone_path" => baseline_clone,
          "candidate_prefix_sha256" => digest_inventory(files),
          "update" => update
        )
      end

      private

      def verify_source!(root)
        inventory(root)
        true
      end

      def inventory(root)
        Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
          next if [ ".", ".." ].include?(File.basename(path))
          relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
          next if relative == ".hive-install.json"
          stat = File.lstat(path)
          raise Error, "channel source contains a symlink" if stat.symlink?
          next if stat.directory?
          raise Error, "channel source contains a non-regular file" unless stat.file? && stat.uid == Process.uid
          [ relative, { "size" => stat.size, "sha256" => Digest::SHA256.file(path).hexdigest } ]
        end.to_h
      end

      def digest_inventory(value)
        Digest::SHA256.hexdigest(JSON.generate(value))
      end
    end

    class FixedPhaseExecutor
      COMMANDS = {
        "latest-stable" => {
          "before" => [ [ "init", "%PROJECT%" ], [ "new", "%PROJECT_NAME%", "release candidate representative task", "--json" ] ],
          "candidate_transition" => [ [ "migrate", "%PROJECT%", "--json" ] ],
          "after" => [ [ "status", "--json" ] ],
          "idempotency" => [ [ "migrate", "%PROJECT%", "--json" ] ]
        },
        "legacy-bench-v041" => {
          "before" => [
            [ "init", "%PROJECT%" ],
            [ "new", "%PROJECT_NAME%", "legacy bench campaign", "--workflow", "bench", "--json" ]
          ],
          "observer" => [
            [ "new", "%PROJECT_NAME%", "collision observer", "--workflow", "bench", "--json" ]
          ],
          "candidate_transition" => [ [ "init", "%PROJECT%", "--workflow", "bench", "--json" ] ],
          "after" => [ [ "status", "--json" ] ],
          "idempotency" => [ [ "init", "%PROJECT%", "--workflow", "bench", "--json" ] ]
        }
      }.freeze
      LEGACY_INSTRUCTIONS = %w[extract generate judge publish].to_h do |stage|
        [ "#{stage}.md", "Legacy local #{stage} instructions.\n" ]
      end.freeze
      LEGACY_DESCRIPTOR = <<~YAML.freeze
        id: bench
        stages:
          - name: inbox
            kind: terminal
            state_file: task.md
          - name: extract
            kind: agent
            state_file: extract.md
            instruction: ./bench/extract.md
            advance_verb: extract
          - name: generate
            kind: agent
            state_file: generate.md
            instruction: ./bench/generate.md
            advance_verb: generate
          - name: judge
            kind: agent
            state_file: judge.md
            instruction: ./bench/judge.md
            advance_verb: judge
          - name: publish
            kind: agent
            state_file: publish.md
            instruction: ./bench/publish.md
            advance_verb: publish
          - name: done
            kind: terminal
            state_file: task.md
      YAML

      def initialize(process_teardown:)
        @process_teardown = process_teardown
      end

      def call(target:, phase:, row:, run_root:)
        project = File.join(run_root, "project")
        environment = target.environment.merge(
          "HIVE_SKIP_LLM_WIKI_SCHEDULER" => "1",
          "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1",
          "HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "1"
        )
        %w[HOME HIVE_HOME XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME].each do |key|
          FileUtils.mkdir_p(environment.fetch(key))
        end
        prepare_source_project!(project) if phase == "before"
        receipts = []
        COMMANDS.fetch(row.id).fetch(phase).each_with_index do |template, index|
          argv = template.map do |argument|
            argument.gsub("%PROJECT%", project).gsub("%PROJECT_NAME%", File.basename(project))
          end
          receipt = @process_teardown.capture(
            target: target, argv: argv, environment: environment,
            cwd: run_root, label: "#{row.id}:#{phase}:#{index + 1}"
          )
          receipts << receipt
          if row.id == "legacy-bench-v041" && phase == "before" && index.zero? && receipt["status"] == "passed"
            install_exact_legacy_bench!(project)
          end
          break unless receipt["status"] == "passed" || phase == "observer"
        end
        seed_representative_state!(
          project: project, environment: environment
        ) if phase == "before" && receipts.all? { |item| item["status"] == "passed" }
        receipt = combine(receipts)
        if phase == "observer"
          exact_collision = receipt["status"] == "failed" &&
            receipt["stderr"].include?("collides with registered workflow :bench")
          receipt = receipt.merge(
            "status" => exact_collision ? "expected_failure_observed" : receipt["status"],
            "reason" => exact_collision ? "legacy_workflow_collision" : "observer_outcome_mismatch",
            "observation" => exact_collision ? {
              "outcome" => "expected_failure",
              "code" => "workflow_id_collision:bench"
            } : nil
          )
        end
        receipt.merge(
          "producer_kind" => "real-installed",
          "target_gem_sha256" => target.manifest.fetch("gem_sha256"),
          "snapshot" => snapshot(
            target: target, row: row, project: project, environment: environment
          ),
          "task_continuation" => phase == "after" ? task_present?(project) : nil,
          "processes" => [], "services" => []
        )
      end

      private

      def prepare_source_project!(project)
        FileUtils.mkdir_p(project)
        return if File.directory?(File.join(project, ".git"))

        run_git!(project, "init", "-b", "main")
        run_git!(project, "config", "user.email", "release-candidate@example.invalid")
        run_git!(project, "config", "user.name", "Hive Release Candidate")
        File.write(File.join(project, "README.md"), "release candidate upgrade fixture\n")
        run_git!(project, "add", "README.md")
        run_git!(project, "commit", "-m", "fixture root")
      end

      def run_git!(project, *argv)
        _stdout, stderr, status = Open3.capture3(
          { "GIT_CONFIG_NOSYSTEM" => "1", "GIT_TERMINAL_PROMPT" => "0" },
          "git", *argv, chdir: project
        )
        raise Error, "cannot prepare upgrade source project: #{stderr.strip}" unless status.success?
      end

      def install_exact_legacy_bench!(project)
        root = File.join(project, ".hive-state", "workflows")
        instruction_root = File.join(root, "bench")
        FileUtils.mkdir_p(instruction_root)
        File.write(File.join(root, "bench.yml"), LEGACY_DESCRIPTOR)
        LEGACY_INSTRUCTIONS.each do |name, content|
          File.write(File.join(instruction_root, name), content)
        end
        run_git!(File.join(project, ".hive-state"), "add", "workflows")
        run_git!(
          File.join(project, ".hive-state"), "commit", "-m",
          "install exact legacy bench descriptor"
        )
      end

      def combine(receipts)
        {
          "status" => receipts.all? { |item| item["status"] == "passed" } ? "passed" : "failed",
          "exit_status" => receipts.last && receipts.last["exit_status"],
          "stdout" => receipts.map { |item| item["stdout"] }.join,
          "stderr" => receipts.map { |item| item["stderr"] }.join,
          "commands" => receipts.map do |item|
            item.slice("label", "role", "argv", "status", "exit_status")
          end
        }
      end

      def seed_representative_state!(project:, environment:)
        state = File.join(project, ".hive-state")
        task = Dir.glob(File.join(state, "stages", "*", "*")).sort.find do |path|
          File.directory?(path) && !File.symlink?(path)
        end
        if task
          state_file = Dir.glob(File.join(task, "*.md")).sort.first
          File.open(state_file, "a") { |file| file.write("\n<!-- WAITING -->\n") } if state_file
        end
        attempt_root = File.join(state, "attempts", "upgrade-fixture-attempt")
        receipt_root = File.join(state, "dispatch-receipts")
        FileUtils.mkdir_p([ attempt_root, receipt_root ])
        File.write(File.join(attempt_root, "record.json"), JSON.generate(
          "schema" => "hive-attempt", "outcome" => "terminal",
          "task_id" => 7
        ))
        File.write(File.join(receipt_root, "upgrade-fixture-attempt.json"), JSON.generate(
          "schema" => "hive-dispatch-receipt", "accepted" => true,
          "task_id" => 7
        ))
        File.write(File.join(environment.fetch("HIVE_HOME"), "install-channel"), "bash\n")
        web = File.join(environment.fetch("XDG_DATA_HOME"), "hive", "web")
        services = File.join(environment.fetch("XDG_CONFIG_HOME"), "systemd", "user")
        FileUtils.mkdir_p([ web, services ])
        File.write(File.join(web, "persistent-data.fixture"), "preserve-across-upgrade\n")
        %w[hive-daemon hive-web].each do |name|
          File.write(
            File.join(services, "#{name}.service"),
            "[Unit]\nDescription=Inert #{name} upgrade fixture\n"
          )
        end
      end

      def snapshot(target:, row:, project:, environment:)
        env = environment
        status = probe_json(target, [ "status", "--json" ], env, project)
        doctor = probe_json(target, [ "doctor", "--json" ], env, project)
        state = File.join(project, ".hive-state")
        config = safe_yaml(File.join(state, "config.yml"))
        tasks = task_snapshot(state)
        sections = {
          "global_registry" => tree(File.join(env.fetch("HIVE_HOME"), "config.yml")),
          "project_registry" => tree(File.join(env.fetch("HIVE_HOME"), "config.yml")),
          "configuration" => config,
          "default_workflow" => config["default_workflow"] || "coding",
          "tasks" => tasks,
          "dependencies" => tasks.transform_values { |task| task["dependencies"] },
          "markers" => tasks.transform_values { |task| task["markers"] },
          "durable_attempts" => tree(File.join(state, "attempts")),
          "dispatch_receipts" => tree(File.join(state, "dispatch-receipts")),
          "channel_sidecars" => tree(File.join(env.fetch("HIVE_HOME"), "install-channel")),
          "managed_web_data" => tree(File.join(env.fetch("XDG_DATA_HOME"), "hive", "web")),
          "service_definitions" => tree(File.join(env.fetch("XDG_CONFIG_HOME"), "systemd", "user")),
          "status_json" => status,
          "doctor_json" => doctor,
          "install_identity" => {
            "role" => target.role,
            "version" => target.manifest.fetch("version"),
            "gem_sha256" => target.manifest.fetch("gem_sha256")
          }
        }
        if row.id == "legacy-bench-v041"
          sections.merge!(
            "legacy_descriptor" => tree(File.join(state, "workflows", "bench.yml"),
                                        File.join(state, "workflows", "bench.legacy.yml.disabled")),
            "legacy_instructions" => tree(File.join(state, "workflows", "bench"),
                                          File.join(state, "workflows", "bench.legacy")),
            "builtin_runtime" => tree(File.join(state, "bench-runtime"))
          )
        end
        sections
      end

      def probe_json(target, argv, environment, cwd)
        receipt = @process_teardown.capture(
          target: target, argv: argv, environment: environment,
          cwd: cwd, label: "snapshot:#{argv.first}"
        )
        JSON.parse(receipt.fetch("stdout"))
      rescue JSON::ParserError
        {
          "status" => receipt && receipt["status"],
          "exit_status" => receipt && receipt["exit_status"],
          "stdout_sha256" => Digest::SHA256.hexdigest(receipt.to_h["stdout"].to_s),
          "stderr_sha256" => Digest::SHA256.hexdigest(receipt.to_h["stderr"].to_s)
        }
      end

      def task_snapshot(state)
        Dir.glob(File.join(state, "stages", "*", "*")).sort.filter_map do |path|
          next unless File.directory?(path) && !File.symlink?(path)
          slug = File.basename(path)
          meta = safe_yaml(File.join(path, "meta.yml"))
          [
            slug,
            {
              "id" => meta["id"], "slug" => meta["slug"] || slug,
              "stage" => File.basename(File.dirname(path)),
              "contents" => tree(path),
              "dependencies" => meta["depends_on"] || [],
              "markers" => Dir.glob(File.join(path, "*")).sort.flat_map do |file|
                next [] unless File.file?(file) && !File.symlink?(file)
                File.binread(file).scan(/<!--\s*([A-Z_]+)(?:\s+[^>]*)?\s*-->/).flatten
              end.uniq.sort
            }
          ]
        end.to_h
      end

      def task_present?(project)
        Dir.glob(File.join(project, ".hive-state", "stages", "*", "*")).any? do |path|
          File.directory?(path) && !File.symlink?(path)
        end
      end

      def safe_yaml(path)
        return {} unless File.file?(path) && !File.symlink?(path)
        value = YAML.safe_load_file(path, aliases: false)
        value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
      rescue Psych::Exception, SystemCallError
        {}
      end

      def tree(*alternatives)
        path = alternatives.find { |candidate| File.exist?(candidate) || File.symlink?(candidate) }
        return { "status" => "absent" } unless path
        stat = File.lstat(path)
        raise Error, "upgrade snapshot refuses symlink #{path}" if stat.symlink?
        if stat.file?
          return {
            "status" => "file", "size" => stat.size,
            "sha256" => Digest::SHA256.file(path).hexdigest
          }
        end
        entries = Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |entry|
          next if [ ".", ".." ].include?(File.basename(entry))
          child = File.lstat(entry)
          raise Error, "upgrade snapshot refuses symlink #{entry}" if child.symlink?
          next if child.directory?
          relative = Pathname.new(entry).relative_path_from(Pathname.new(path)).to_s
          [ relative, { "size" => child.size, "sha256" => Digest::SHA256.file(entry).hexdigest } ]
        end
        { "status" => "directory", "files" => entries.to_h }
      end
    end

    PHASES = {
      "latest-stable" => [
        [ "baseline", "before" ],
        [ "candidate", "candidate_transition" ],
        [ "candidate", "after" ],
        [ "candidate", "idempotency" ]
      ],
      "legacy-bench-v041" => [
        [ "baseline", "before" ],
        [ "observer", "observer" ],
        [ "candidate", "candidate_transition" ],
        [ "candidate", "after" ],
        [ "candidate", "idempotency" ]
      ]
    }.freeze
    ALLOWED_MIGRATIONS = {
      "latest-stable" => %w[
        /install_identity
      ],
      "legacy-bench-v041" => %w[
        /builtin_runtime
        /install_identity
        /legacy_descriptor
        /legacy_instructions
      ]
    }.freeze
    OUTPUT_LIMIT = 64 * 1024

    def initialize(catalog:, targets:, run_root:, sandbox_contract:, cache_contract:,
                   candidate_manifest:, phase_executor: nil, channel_executor: nil,
                   process_teardown: nil)
      @catalog = catalog
      @targets = targets.transform_keys(&:to_s)
      @run_root = prepare_run_root!(run_root)
      @sandbox_contract = sandbox_contract
      @cache_contract = cache_contract
      @process_teardown = process_teardown || ProcessTeardown.new
      @candidate_manifest = candidate_manifest
      @phase_executor = phase_executor || FixedPhaseExecutor.new(process_teardown: @process_teardown)
      @channel_executor = channel_executor || FixedChannelExecutor.new(targets: @targets)
    end

    def run(row_id:, platform:)
      entry = @catalog.fetch(row_id)
      unavailable = preflight(entry, platform)
      return unavailable if unavailable

      receipts = execute_phases(entry)
      reasons = validate_phase_receipts(entry, receipts)
      snapshots = snapshot_receipts(entry, receipts, reasons)
      compare_invariants(entry, snapshots, reasons)
      channel = execute_channel(entry, platform, reasons)
      teardown = execute_teardown(receipts, reasons)
      status = reasons.empty? ? "passed" : "failed"
      {
        "schema" => "hive-release-candidate-upgrade-survivor",
        "schema_version" => SCHEMA_VERSION,
        "row_id" => entry.id,
        "platform" => platform,
        "status" => status,
        "reason" => reasons.first,
        "reasons" => reasons.uniq,
        "phases" => receipts,
        "invariants" => snapshots,
        "channel" => channel,
        "teardown" => teardown,
        "trust_scope" => "local",
        "qa_status" => "qa_blocked",
        "blockers" => [ "remote_validation_required" ] + reasons.uniq
      }
    rescue Error => e
      failed(entry&.id || row_id, platform, e.message)
    rescue StandardError => e
      failed(entry&.id || row_id, platform, "upgrade_runner_error", diagnostic: e.message)
    end

    private

    def preflight(entry, platform)
      unless entry.required_platforms.include?(platform)
        return unavailable(entry.id, platform, "baseline_platform_incompatible")
      end
      unless @sandbox_contract.is_a?(Hash) &&
             @sandbox_contract["status"] == "available" &&
             @sandbox_contract["network_after_staging"] == "none"
        return unavailable(entry.id, platform, "disposable_sandbox_unavailable")
      end
      unless @cache_contract.is_a?(Hash) &&
             @cache_contract["status"] == "available" &&
             /\A[0-9a-f]{64}\z/.match?(@cache_contract["release_assets_sha256"].to_s) &&
             /\A[0-9a-f]{64}\z/.match?(@cache_contract["verified_dependency_closure_sha256"].to_s)
        return unavailable(entry.id, platform, "authenticated_baseline_cache_unavailable")
      end
      required_roles = PHASES.fetch(entry.id).map(&:first).uniq
      missing = required_roles.reject { |role| @targets[role].is_a?(InstalledTarget) }
      unless missing.empty?
        reason = missing.include?("observer") ?
          "required_observer_target_unavailable" : "required_installed_target_unavailable"
        return unavailable(entry.id, platform, reason)
      end
      mismatched = required_roles.find { |role| @targets.fetch(role).role != role }
      return unavailable(entry.id, platform, "installed_target_role_mismatch") if mismatched

      producer = entry.packages.fetch("producer")
      baseline = @targets.fetch("baseline")
      unless baseline.manifest["version"] == producer.fetch("version") &&
             baseline.manifest["gem_sha256"] == producer.dig("artifact", "sha256")
        return unavailable(entry.id, platform, "baseline_target_identity_mismatch")
      end
      if entry.packages["observer"]
        observer = @targets.fetch("observer")
        package = entry.packages.fetch("observer")
        unless observer.manifest["version"] == package.fetch("version") &&
               observer.manifest["gem_sha256"] == package.dig("artifact", "sha256")
          return unavailable(entry.id, platform, "observer_target_identity_mismatch")
        end
      end
      candidate = @targets.fetch("candidate")
      candidate_gem = @candidate_manifest.is_a?(Hash) &&
        @candidate_manifest["files"].is_a?(Hash) &&
        @candidate_manifest["files"].values.find { |record| record["kind"] == "gem" }
      unless @candidate_manifest.is_a?(Hash) &&
             SAFE_SHA.match?(@candidate_manifest["candidate_sha"].to_s) &&
             @candidate_manifest["hive_version"] == candidate.manifest["version"] &&
             candidate_gem &&
             candidate_gem["sha256"] == candidate.manifest["gem_sha256"]
        return unavailable(entry.id, platform, "candidate_target_identity_mismatch")
      end
      nil
    end

    def execute_phases(entry)
      PHASES.fetch(entry.id).map do |role, phase|
        target = @targets.fetch(role)
        receipt = @phase_executor.call(
          target: target, phase: phase, row: entry, run_root: @run_root
        )
        normalize_receipt(receipt, role: role, phase: phase)
      rescue StandardError => e
        {
          "role" => role, "phase" => phase, "status" => "failed",
          "reason" => "phase_execution_failed", "diagnostic" => bounded(e.message),
          "stdout" => "", "stderr" => "", "processes" => [], "services" => []
        }
      end
    end

    def normalize_receipt(value, role:, phase:)
      raise Error, "#{phase} phase did not return evidence" unless value.is_a?(Hash)

      value.transform_keys(&:to_s).merge(
        "role" => role, "phase" => phase,
        "stdout" => bounded(value["stdout"].to_s),
        "stderr" => bounded(value["stderr"].to_s),
        "stdout_truncated" => value["stdout"].to_s.bytesize > OUTPUT_LIMIT,
        "stderr_truncated" => value["stderr"].to_s.bytesize > OUTPUT_LIMIT,
        "processes" => Array(value["processes"]),
        "services" => Array(value["services"])
      )
    end

    def validate_phase_receipts(entry, receipts)
      reasons = []
      receipts.each do |receipt|
        expected = receipt["phase"] == "observer" ? "expected_failure_observed" : "passed"
        reasons << (receipt["reason"] || "upgrade_phase_failed") unless receipt["status"] == expected
      end
      producer = receipts.first
      reasons << "fixture_cannot_substitute_for_real_producer" unless producer["producer_kind"] == "real-installed"
      unless producer["target_gem_sha256"] == entry.packages.dig("producer", "artifact", "sha256")
        reasons << "producer_identity_mismatch"
      end
      if entry.id == "legacy-bench-v041"
        observer = receipts.find { |receipt| receipt["phase"] == "observer" }
        unless observer &&
               observer["producer_kind"] == "real-installed" &&
               observer["target_gem_sha256"] == entry.packages.dig("observer", "artifact", "sha256") &&
               observer["reason"] == "legacy_workflow_collision" &&
               observer["observation"] == {
                 "outcome" => "expected_failure",
                 "code" => "workflow_id_collision:bench"
               }
          reasons << "required_broken_intermediate_observation_missing"
        end
        after = receipts.find { |receipt| receipt["phase"] == "after" }
        reasons << "legacy_task_cannot_continue" unless after && after["task_continuation"] == true
      end
      reasons
    end

    def snapshot_receipts(entry, receipts, reasons)
      receipts.to_h do |receipt|
        sections = receipt["snapshot"]
        begin
          [ receipt.fetch("phase"), InvariantSnapshot.build(row_id: entry.id, sections: sections) ]
        rescue Error => e
          reasons << "invalid_#{receipt.fetch('phase')}_snapshot"
          [ receipt.fetch("phase"), { "status" => "invalid", "diagnostic" => bounded(e.message) } ]
        end
      end
    end

    def compare_invariants(entry, snapshots, reasons)
      before = snapshots["before"]
      after = snapshots["after"]
      idempotency = snapshots["idempotency"]
      if valid_snapshot?(before) && valid_snapshot?(after)
        transition = InvariantSnapshot.compare(
          before: before, after: after,
          allowed_migrations: ALLOWED_MIGRATIONS.fetch(entry.id)
        )
        snapshots["transition_diff"] = transition
        reasons << "invariant_mismatch" unless transition["passed"]
      end
      if valid_snapshot?(after) && valid_snapshot?(idempotency)
        repeat = InvariantSnapshot.compare(
          before: after, after: idempotency, allowed_migrations: []
        )
        snapshots["idempotency_diff"] = repeat
        reasons << "second_run_not_idempotent" unless repeat["passed"]
      end
    end

    def execute_channel(entry, platform, reasons)
      candidate = @targets.fetch("candidate")
      receipt = @channel_executor.call(
        row: entry, platform: platform, candidate_target: candidate, run_root: @run_root
      )
      unless receipt.is_a?(Hash)
        reasons << "channel_evidence_missing"
        return { "status" => "failed", "reason" => "channel_evidence_missing" }
      end
      expected_channel = ChannelPrefixOracle::CHANNELS.fetch(platform)
      checks = receipt["status"] == "passed" &&
        receipt["channel"] == expected_channel &&
        receipt["candidate_gem_sha256"] == candidate.manifest.fetch("gem_sha256") &&
        receipt["stale_files"] == [] &&
        receipt["wrapper_role"] == "candidate" &&
        receipt["sidecars_current"] == true &&
        receipt["dependencies_current"] == true
      unless checks
        reasons << receipt["reason"].to_s unless receipt["reason"].to_s.empty?
        reasons << "channel_faithful_update_failed"
      end
      receipt
    rescue StandardError => e
      reasons << "channel_faithful_update_failed"
      { "status" => "failed", "reason" => "channel_faithful_update_failed", "diagnostic" => bounded(e.message) }
    end

    def execute_teardown(receipts, reasons)
      processes = receipts.flat_map { |receipt| receipt.fetch("processes", []) }
      services = receipts.flat_map { |receipt| receipt.fetch("services", []) }
      @process_teardown.verify!(processes: processes, services: services)
    rescue Error => e
      reasons << "upgrade_process_leak"
      { "status" => "failed", "reason" => "upgrade_process_leak", "diagnostic" => bounded(e.message) }
    end

    def valid_snapshot?(value)
      value.is_a?(Hash) && value["schema"] == "hive-release-candidate-invariant-snapshot"
    end

    def prepare_run_root!(value)
      root = File.expand_path(value)
      parent = File.dirname(root)
      parent_stat = File.lstat(parent)
      unless parent_stat.directory? && !parent_stat.symlink? && parent_stat.uid == Process.uid
        raise Error, "upgrade run parent must be an owned directory"
      end
      Dir.mkdir(root, 0o700) unless File.exist?(root) || File.symlink?(root)
      stat = File.lstat(root)
      unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
        raise Error, "upgrade run root must be an owned directory"
      end
      root
    rescue Errno::ENOENT, Errno::EACCES, Errno::EEXIST
      raise Error, "upgrade run root must be an owned directory"
    end

    def unavailable(row_id, platform, reason)
      {
        "schema" => "hive-release-candidate-upgrade-survivor",
        "schema_version" => SCHEMA_VERSION,
        "row_id" => row_id, "platform" => platform,
        "status" => "unavailable", "reason" => reason,
        "reasons" => [ reason ], "phases" => [],
        "trust_scope" => "local", "qa_status" => "qa_blocked",
        "blockers" => [ "remote_validation_required", reason ],
        "next_action_argv" => [
          "bin/hive-release-candidate", "dispatch", "--sha",
          @candidate_manifest.is_a?(Hash) && SAFE_SHA.match?(@candidate_manifest["candidate_sha"].to_s) ?
            @candidate_manifest.fetch("candidate_sha") : "<candidate-sha>"
        ]
      }
    end

    def failed(row_id, platform, reason, diagnostic: nil)
      unavailable(row_id, platform, reason).merge(
        "status" => "failed", "diagnostic" => diagnostic
      )
    end

    def bounded(value)
      string = value.to_s
      string.bytesize > OUTPUT_LIMIT ? string.byteslice(0, OUTPUT_LIMIT) : string
    end
  end
end
