require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "time"
require "yaml"
require_relative "../../../lib/hive/secret_patterns"

module Hive
  module E2E
    # Reduced, opt-in U3b successor. It qualifies real persisted shadow records
    # through an exact archived/installed candidate's public CLI. It does not
    # manufacture Patrol state or claim that same-head controls are independent.
    module PatrolQualification
      MODULES = %w[architecture-patrol patrol].freeze
      EXTERNAL_FAULTS = %w[
        cli_failure finalized_outbox_reconciliation_recovery none
        post_reservation_capture_decision_restart provider_failure released_attempt_retry
      ].freeze
      MAX_STREAM_BYTES = 1 * 1024 * 1024
      MAX_STDIN_BYTES = 8 * 1024 * 1024
      MAX_EVIDENCE_BYTES = 512 * 1024
      MAX_SHADOW_FILES = 64
      MAX_SHADOW_BYTES = 8 * 1024 * 1024
      CHILD_TIMEOUT = 30.0
      CHILD_TIMEOUT_STATUS = 124
      TERMINAL_SIGNALS = %w[
        HUP INT QUIT ILL TRAP ABRT IOT FPE KILL BUS SEGV SYS PIPE ALRM TERM
        XCPU XFSZ VTALRM PROF USR1 USR2 PWR IO POLL
      ].filter_map { |name| Signal.list[name] }.uniq.freeze
      GIT_OVERRIDES = [
        "-c", "core.hooksPath=/dev/null",
        "-c", "commit.gpgsign=false",
        "-c", "tag.gpgsign=false",
        "-c", "credential.helper="
      ].freeze

      class Error < StandardError; end
      class ChildTimeout < Error; end
      class CampaignTimeout < Error; end

      class ProcessFailure < Error
        attr_reader :kind, :status

        def initialize(kind, status, label)
          @kind = kind
          @status = status
          super("#{label} failed (#{kind}=#{status})")
        end
      end

      Result = Data.define(:stdout, :stderr, :status)
      Case = Data.define(:id, :module_name, :decision_class, :fault)

      module_function

      def canonical(value)
        JSON.generate(canonical_value(value)) + "\n"
      end

      def canonical_value(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.to_h do |key|
            original = value.key?(key) ? key : value.keys.find { |item| item.to_s == key }
            [ key, canonical_value(value.fetch(original)) ]
          end
        when Array then value.map { |item| canonical_value(item) }
        else value
        end
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def check_deadline!(deadline, label)
        return unless deadline && monotonic >= deadline

        raise CampaignTimeout, "qualification campaign deadline expired while reading #{label}"
      end

      def bounded_read(path, label:, limit: MAX_EVIDENCE_BYTES, deadline: nil)
        check_deadline!(deadline, label)
        raise Error, "#{label} cannot be opened without following links" unless
          File.const_defined?(:NOFOLLOW) && File.const_defined?(:NONBLOCK)

        flags = File::RDONLY | File::NOFOLLOW | File::NONBLOCK
        File.open(path, flags) do |file|
          stat = file.stat
          raise Error, "#{label} must be a bounded regular file" unless
            stat.file? && stat.size <= limit
          bytes = file.read(limit + 1)
          raise Error, "#{label} exceeds its byte bound" if bytes.bytesize > limit
          check_deadline!(deadline, label)
          bytes
        end
      rescue Errno::ELOOP, Errno::ENXIO, SystemCallError => e
        raise Error, "#{label} is unreadable: #{e.message}"
      end

      class Catalog
        attr_reader :cases, :contracts, :expectations, :bytes

        def self.load(path, deadline: nil)
          new(PatrolQualification.bounded_read(
            path, label: "qualification catalogue", deadline: deadline
          ))
        end

        def initialize(bytes)
          @bytes = bytes.freeze
          data = JSON.parse(bytes)
          exact_keys!(data, %w[cases contracts expectations schema schema_version])
          unless data["schema"] == "hive-patrol-reduced-qualification-catalog" &&
                 data["schema_version"] == 1
            raise Error, "qualification catalogue schema is unsupported"
          end
          @cases = data.fetch("cases").map { |row| parse_case(row) }.freeze
          @contracts = data.fetch("contracts").map { |row| parse_contract(row) }.freeze
          @expectations = parse_expectations(data.fetch("expectations")).freeze
          validate_inventory!
        rescue JSON::ParserError, KeyError, TypeError => e
          raise Error, "qualification catalogue is malformed: #{e.message}"
        end

        private

        def parse_case(row)
          exact_keys!(row, %w[decision_class fault id module proof_kind])
          valid = row["proof_kind"] == "e2e" && safe_id?(row["id"]) &&
            MODULES.include?(row["module"]) && EXTERNAL_FAULTS.include?(row["fault"]) &&
            nonempty?(row["decision_class"])
          raise Error, "qualification E2E case is malformed" unless valid

          Case.new(row["id"], row["module"], row["decision_class"], row["fault"]).freeze
        end

        def parse_contract(row)
          exact_keys!(row, %w[id proof_kind test_file test_method])
          valid = safe_id?(row["id"]) && row["proof_kind"] == "focused_test" &&
            row["test_file"].to_s.start_with?("test/") &&
            row["test_method"].to_s.match?(/\Atest_[a-z0-9_]+\z/)
          raise Error, "qualification focused-test contract is malformed" unless valid
          row.freeze
        end

        def parse_expectations(value)
          exact_keys!(value, MODULES)
          value.to_h do |name, row|
            exact_keys!(row, %w[change_window_count decision_classes decision_count repository_sha_count])
            valid = row.values_at("decision_count", "repository_sha_count", "change_window_count")
                       .all? { |number| number.is_a?(Integer) && number.positive? } &&
              row["decision_classes"].is_a?(Array) &&
              row["decision_classes"].all? { |item| nonempty?(item) }
            raise Error, "qualification expectation is malformed" unless valid
            [ name, row.freeze ]
          end
        end

        def validate_inventory!
          ids = cases.map(&:id) + contracts.map { |row| row.fetch("id") }
          raise Error, "qualification IDs are not unique" unless ids.uniq == ids
          MODULES.each do |name|
            rows = cases.select { |row| row.module_name == name }
            expected = expectations.fetch(name)
            raise Error, "qualification case cardinality differs for #{name}" unless
              rows.size == expected.fetch("decision_count")
            raise Error, "qualification decision classes differ for #{name}" unless
              rows.map(&:decision_class).uniq.sort == expected.fetch("decision_classes").sort
          end
        end

        def exact_keys!(value, keys)
          raise Error, "qualification catalogue keys are malformed" unless
            value.is_a?(Hash) && value.keys.sort == keys.sort
        end

        def safe_id?(value) = value.is_a?(String) && value.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
        def nonempty?(value) = value.is_a?(String) && !value.empty?
      end

      class ChildProcess
        def initialize(deadline:, env:)
          @deadline = deadline
          @env = env.freeze
        end

        def run(*command, label:, cwd:, stdin_data: "", timeout: CHILD_TIMEOUT)
          raise Error, "#{label} stdin exceeds its bound" if stdin_data.bytesize > MAX_STDIN_BYTES
          remaining = @deadline - monotonic
          raise CampaignTimeout, "qualification campaign deadline expired" unless remaining.positive?
          campaign_limited = remaining <= timeout
          limit = [ remaining, timeout ].min
          command_deadline = monotonic + limit
          stdout = +""
          stderr = +""
          status = nil
          pid = nil
          cleaned_up = false
          streams = []
          workers = []
          Open3.popen3(@env, *command, chdir: cwd, pgroup: true, unsetenv_others: true) do |input, out, err, wait|
            pid = wait.pid
            input.binmode
            streams = [ input, out, err ]
            workers = [ Thread.new { drain(out, stdout) }, Thread.new { drain(err, stderr) } ]
            workers << Thread.new do
              input.write(stdin_data)
            rescue Errno::EPIPE, IOError
              nil
            ensure
              close(input)
            end
            workers.each { |thread| thread.report_on_exception = false }
            unless wait.join(limit)
              terminate_group(pid)
              streams.each { |io| close(io) }
              join_until(workers, monotonic + 0.5)
              cleaned_up = true
              raise(campaign_limited ? CampaignTimeout : ChildTimeout,
                    "#{label} exceeded #{limit.round(3)} seconds")
            end
            status = wait.value
            terminate_group(pid)
            cleaned_up = true
            unless join_until(workers, command_deadline)
              terminate_group(pid)
              streams.each { |io| close(io) }
              join_until(workers, monotonic + 0.5)
              raise(campaign_limited ? CampaignTimeout : ChildTimeout,
                    "#{label} did not close its process streams before the deadline")
            end
          end
          unless status.success?
            kind, value = status.signaled? ? [ "signal", status.termsig ] : [ "exit", status.exitstatus ]
            raise ProcessFailure.new(kind, value, label)
          end
          Result.new(stdout.freeze, stderr.freeze, status.exitstatus).freeze
        rescue SystemCallError => e
          raise ProcessFailure.new("spawn", e.class.name, label)
        ensure
          if pid && !cleaned_up
            terminate_group(pid)
            streams.each { |io| close(io) }
            join_until(workers, monotonic + 0.5)
          end
        end

        private

        def drain(io, destination)
          while (chunk = io.read(16 * 1024))
            remaining = MAX_STREAM_BYTES - destination.bytesize
            destination << chunk.byteslice(0, remaining) if remaining.positive?
          end
        rescue IOError
          nil
        end

        def terminate_group(pid)
          Process.kill("TERM", -pid)
          deadline = monotonic + 0.5
          sleep 0.02 while monotonic < deadline && process_group_alive?(pid)
          Process.kill("KILL", -pid) if process_group_alive?(pid)
          Process.waitpid(pid) rescue nil
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end

        def process_group_alive?(pid)
          Process.kill(0, -pid)
          true
        rescue Errno::ESRCH
          false
        end

        def join_until(threads, deadline)
          threads.each do |thread|
            remaining = deadline - monotonic
            break unless remaining.positive?
            thread.join(remaining)
          end
          threads.none?(&:alive?)
        end

        def close(io)
          io.close unless io.closed?
        rescue IOError, SystemCallError
          nil
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      class ObservationReader
        attr_reader :bytes

        OBSERVATION_KEYS = %w[
          change_window fault_observed id process_outcomes repository_sha trigger_id
        ].freeze
        OUTCOME_KEYS = %w[kind status].freeze
        OUTCOME_KINDS = %w[child_timeout exit signal].freeze

        def initialize(project_root:, observations_path:, catalog:, deadline: nil)
          @project_root = File.expand_path(project_root)
          @catalog = catalog
          @deadline = deadline
          @observations = read_observations(observations_path)
        end

        def each
          records = comparable_records
          selected = []
          @catalog.cases.each do |case_row|
            observation = @observations.fetch(case_row.id)
            unless observation.fetch("fault_observed") == case_row.fault
              raise Error, "#{case_row.id} fault observation differs from the catalogue"
            end
            matches = records.select do |record|
              record.fetch("module") == case_row.module_name &&
                record.dig("trigger", "id") == observation.fetch("trigger_id")
            end
            raise Error, "#{case_row.id} does not select exactly one shadow record" unless matches.one?
            record = matches.first
            unless record.dig("module_decision", "rationale") == case_row.decision_class
              raise Error, "#{case_row.id} decision class differs from the catalogue"
            end
            selected << [ record.fetch("module"), record.dig("trigger", "id") ]
            yield case_row, observation, record
          end
          unless selected.uniq.size == records.size
            raise Error, "qualification selectors do not cover each shadow record exactly once"
          end
          validate_cardinality!(records)
        end

        private

        def read_observations(path)
          @bytes = PatrolQualification.bounded_read(
            path, label: "qualification observations", deadline: @deadline
          ).freeze
          data = JSON.parse(@bytes)
          unless data.is_a?(Hash) && data.keys.sort == %w[cases schema schema_version] &&
                 data["schema"] == "hive-patrol-reduced-observations" && data["schema_version"] == 1
            raise Error, "qualification observations are malformed"
          end
          rows = data.fetch("cases")
          raise Error, "qualification observation cardinality is malformed" unless rows.is_a?(Array)
          ids = rows.map { |row| row.is_a?(Hash) ? row["id"] : nil }
          unless ids.none?(&:nil?) && ids.uniq.size == ids.size
            raise Error, "qualification observation IDs are duplicated"
          end
          unless rows.size == @catalog.cases.size
            raise Error, "qualification observation cardinality is malformed"
          end
          result = rows.to_h do |row|
            raise Error, "qualification observation keys are malformed" unless
              row.is_a?(Hash) && row.keys.sort == OBSERVATION_KEYS
            valid = row["repository_sha"].to_s.match?(/\A[0-9a-f]{40}\z/) &&
              EXTERNAL_FAULTS.include?(row["fault_observed"]) &&
              [ row["id"], row["trigger_id"], row["change_window"] ].all? { |item| item.is_a?(String) && !item.empty? }
            valid &&= valid_process_outcomes?(row)
            raise Error, "qualification observation is malformed" unless valid
            [ row.fetch("id"), row.freeze ]
          end
          raise Error, "qualification observation IDs differ from the catalogue" unless
            result.keys.sort == @catalog.cases.map(&:id).sort
          result.freeze
        rescue JSON::ParserError, KeyError => e
          raise Error, "qualification observations are malformed: #{e.message}"
        end

        def valid_process_outcomes?(row)
          outcomes = row["process_outcomes"]
          return false unless outcomes.is_a?(Array) && !outcomes.empty? && outcomes.size <= 4
          return false unless outcomes.all? do |outcome|
            next false unless outcome.is_a?(Hash) && outcome.keys.sort == OUTCOME_KEYS &&
                              OUTCOME_KINDS.include?(outcome["kind"])

            case outcome["kind"]
            when "exit"
              outcome["status"].is_a?(Integer) && outcome["status"].between?(0, 255)
            when "signal"
              outcome["status"].is_a?(Integer) && TERMINAL_SIGNALS.include?(outcome["status"])
            when "child_timeout"
              outcome["status"] == CHILD_TIMEOUT_STATUS
            end
          end

          failed = ->(outcome) { outcome["kind"] != "exit" || outcome["status"] != 0 }
          successful = ->(outcome) { outcome == { "kind" => "exit", "status" => 0 } }
          case row.fetch("fault_observed")
          when "none" then outcomes.one? && successful.call(outcomes.first)
          when "provider_failure", "cli_failure" then outcomes.any? { |item| failed.call(item) }
          when "post_reservation_capture_decision_restart"
            outcomes.first["kind"] == "signal" && outcomes.any? { |item| successful.call(item) }
          when "released_attempt_retry"
            outcomes.size >= 2 && failed.call(outcomes.first) && successful.call(outcomes.last)
          when "finalized_outbox_reconciliation_recovery"
            outcomes.size >= 2 && outcomes.first["kind"] == "signal" && successful.call(outcomes.last)
          else false
          end
        end

        def comparable_records
          root = File.join(state_path, "module-runtime", "migration", "shadow")
          records = []
          extra = false
          file_count = 0
          byte_count = 0
          MODULES.each do |name|
            directory = File.join(root, name)
            directory_stat = File.lstat(directory)
            raise Error, "shadow evidence directory must not be linked" unless
              directory_stat.directory? && !directory_stat.symlink?
            paths = []
            Dir.foreach(directory) do |entry|
              next if entry == "." || entry == ".."

              PatrolQualification.check_deadline!(@deadline, "shadow inventory")
              file_count += 1
              raise Error, "shadow evidence exceeds its file-count bound" if file_count > MAX_SHADOW_FILES
              raise Error, "shadow evidence contains an unexpected child" unless entry.match?(/\A[0-9a-f]{64}\.json\z/)
              paths << File.join(directory, entry)
            end
            paths.sort.each do |path|
              bytes = PatrolQualification.bounded_read(
                path, label: "shadow evidence", deadline: @deadline
              )
              byte_count += bytes.bytesize
              raise Error, "shadow evidence exceeds its aggregate byte bound" if byte_count > MAX_SHADOW_BYTES
              record = JSON.parse(bytes)
              unless bytes == PatrolQualification.canonical(record)
                raise Error, "shadow evidence is not canonical JSON"
              end
              next unless record["comparable"] == true && record["legacy_capture"]

              if records.size < @catalog.cases.size
                records << record
              else
                extra = true
              end
            end
          end
          raise Error, "shadow evidence contains extra or missing comparable records" unless
            !extra && records.size == @catalog.cases.size
          records
        rescue JSON::ParserError, SystemCallError, TypeError => e
          raise Error, "shadow evidence is unreadable: #{e.message}"
        end

        def validate_cardinality!(records)
          MODULES.each do |name|
            rows = records.select { |record| record.fetch("module") == name }
            observations = @catalog.cases.select { |item| item.module_name == name }
                                        .map { |item| @observations.fetch(item.id) }
            expected = @catalog.expectations.fetch(name)
            actual = {
              "decision_count" => rows.size,
              "repository_sha_count" => observations.map { |row| row.fetch("repository_sha") }.uniq.size,
              "change_window_count" => observations.map { |row| row.fetch("change_window") }.uniq.size
            }
            actual.each do |key, value|
              raise Error, "#{name} #{key} differs from the catalogue" unless value == expected.fetch(key)
            end
            classes = rows.map { |record| record.dig("module_decision", "rationale") }.uniq.sort
            raise Error, "#{name} decision classes differ from the catalogue" unless
              classes == expected.fetch("decision_classes").sort
            configurations = rows.map { |record| record["configuration_digest"] }.uniq
            raise Error, "#{name} configuration is missing or changed" unless
              configurations.one? && configurations.first.to_s.match?(/\A[0-9a-f]{64}\z/)
          end
        end

        def state_path
          config = YAML.safe_load(PatrolQualification.bounded_read(
            File.join(@project_root, ".hive-state", "config.yml"),
            label: "qualification project config", deadline: @deadline
          )) || {}
          File.expand_path(config.fetch("hive_state_path", ".hive-state"), @project_root)
        rescue Psych::Exception, SystemCallError
          File.join(@project_root, ".hive-state")
        end
      end

      class Controller
        def initialize(repo_root:, project_root:, hive_home:, observations_path:, evidence_root:,
                       campaign_timeout: 300.0, child_timeout: CHILD_TIMEOUT)
          @repo_root = File.expand_path(repo_root)
          @project_root = File.expand_path(project_root)
          @hive_home = File.expand_path(hive_home)
          @observations_path = File.expand_path(observations_path)
          @evidence_root = File.expand_path(evidence_root)
          @deadline = monotonic + campaign_timeout
          @child_timeout = child_timeout
        end

        def run!
          Dir.mktmpdir("hive-patrol-u3br") do |run_root|
            setup_process(run_root)
            candidate = materialize_candidate(run_root)
            catalog = Catalog.load(
              File.join(candidate.fetch("root"), "test/e2e/fixtures/patrol_qualification/catalog.json"),
              deadline: @deadline
            )
            install_candidate(candidate, run_root)
            catalog_repo = build_module_catalog(candidate, run_root)
            install_modules(catalog_repo)
            prepared = collect_receipts(catalog, candidate)
            report = admit_qualification(prepared)
            proof = proof(candidate, catalog, report, prepared)
            write_evidence(proof)
            proof
          rescue StandardError => e
            write_evidence("status" => "failed", "error_class" => e.class.name,
                           "error" => e.message.to_s.byteslice(0, 2048))
            raise
          end
        end

        private

        def setup_process(run_root)
          @env = {
            "HOME" => @hive_home, "HIVE_HOME" => @hive_home,
            "GIT_ATTR_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null",
            "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_SYSTEM" => "/dev/null",
            "GIT_CONFIG_COUNT" => "4",
            "GIT_CONFIG_KEY_0" => "core.hooksPath", "GIT_CONFIG_VALUE_0" => "/dev/null",
            "GIT_CONFIG_KEY_1" => "commit.gpgsign", "GIT_CONFIG_VALUE_1" => "false",
            "GIT_CONFIG_KEY_2" => "tag.gpgsign", "GIT_CONFIG_VALUE_2" => "false",
            "GIT_CONFIG_KEY_3" => "credential.helper", "GIT_CONFIG_VALUE_3" => "",
            "GIT_TERMINAL_PROMPT" => "0",
            "HIVE_SKIP_LLM_WIKI_SCHEDULER" => "1", "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1",
            "HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "1", "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8",
            "PATH" => [ File.dirname(RbConfig.ruby), "/usr/bin", "/bin" ].join(":"),
            "TMPDIR" => run_root
          }.freeze
          @process = ChildProcess.new(deadline: @deadline, env: @env)
        end

        def materialize_candidate(run_root)
          sha = git("-C", @repo_root, "rev-parse", "HEAD", label: "resolve candidate").stdout.strip
          raise Error, "candidate HEAD is not a full SHA" unless sha.match?(/\A[0-9a-f]{40}\z/)
          status = git("-C", @repo_root, "status", "--porcelain", "--untracked-files=all",
                       label: "inspect candidate").stdout
          raise Error, "qualification requires a clean candidate checkout" unless status.empty?
          archive = File.join(run_root, "candidate.tar")
          git("-C", @repo_root, "archive", "--format=tar", "--output", archive, sha,
              label: "archive candidate")
          root = File.join(run_root, "candidate")
          FileUtils.mkdir_p(root)
          run("tar", "-xf", archive, "-C", root, label: "materialize candidate")
          executing_controller = PatrolQualification.bounded_read(
            File.expand_path(__FILE__), label: "executing qualification controller", deadline: @deadline
          )
          archived_controller = PatrolQualification.bounded_read(
            File.join(root, "test/e2e/lib/patrol_qualification.rb"),
            label: "archived qualification controller", deadline: @deadline
          )
          unless Digest::SHA256.digest(executing_controller) == Digest::SHA256.digest(archived_controller)
            raise Error, "executing qualification controller differs from the archived candidate"
          end
          captured_head = git("-C", @repo_root, "rev-parse", "HEAD",
                              label: "recheck candidate head").stdout.strip
          captured_status = git("-C", @repo_root, "status", "--porcelain", "--untracked-files=all",
                                label: "recheck candidate cleanliness").stdout
          unless captured_head == sha && captured_status.empty?
            raise Error, "candidate checkout changed while its archive was captured"
          end
          { "sha" => sha, "archive_sha256" => Digest::SHA256.file(archive).hexdigest, "root" => root }
        end

        def install_candidate(candidate, run_root)
          gem_file = File.join(run_root, "candidate.gem")
          run("gem", "build", "hive.gemspec", "--output", gem_file,
              cwd: candidate.fetch("root"), label: "build candidate gem")
          install_root = File.join(run_root, "installed")
          installer = File.join(candidate.fetch("root"), "packaging/live_agent_skills/install_candidate_gem.sh")
          run("/bin/bash", installer, gem_file, install_root, label: "install candidate gem")
          @hive_bin = File.join(install_root, "bin", "hive")
          stat = File.lstat(@hive_bin)
          unless stat.file? && !stat.symlink? && File.executable?(@hive_bin)
            raise Error, "candidate installer did not publish a regular bin/hive"
          end
          candidate["gem_sha256"] = Digest::SHA256.file(gem_file).hexdigest
          candidate["installed_hive_sha256"] = Digest::SHA256.file(@hive_bin).hexdigest
        end

        def build_module_catalog(candidate, run_root)
          root = File.join(run_root, "catalog")
          entries = MODULES.map do |name|
            source = File.join(candidate.fetch("root"), "modules", name)
            manifest = YAML.safe_load(File.binread(File.join(source, "manifest.yml")))
            version = manifest.fetch("version")
            destination = File.join(root, "modules", name, version)
            FileUtils.mkdir_p(File.dirname(destination))
            FileUtils.cp_r(source, destination)
            {
              "name" => name, "version" => version, "latest_version" => version,
              "type" => manifest.fetch("type"), "description" => manifest.fetch("description"),
              "state" => "listed", "discoverable" => true,
              "source_sha" => manifest.dig("source", "revision"),
              "manifest_sha256" => manifest.fetch("release_sha256"),
              "package_path" => "modules/#{name}/#{version}"
            }
          end
          @catalog_manifests = entries.to_h { |entry| [ entry.fetch("name"), entry ] }
          File.binwrite(File.join(root, "catalog.json"), PatrolQualification.canonical(
            "schema" => "honeycomb-catalog/v3", "entries" => entries
          ))
          git("init", "-b", "main", "--quiet", cwd: root, label: "initialize local catalog")
          git("add", "--", ".", cwd: root, label: "stage local catalog")
          git("-c", "user.email=qualification@example.invalid",
              "-c", "user.name=Hive qualification", "-c", "commit.gpgsign=false",
              "commit", "-m", "qualification catalog", "--quiet",
              cwd: root, label: "commit local catalog")
          @catalog_commit = git("rev-parse", "HEAD", cwd: root, label: "resolve local catalog").stdout.strip
          root
        end

        def install_modules(catalog_repo)
          rewrite = {
            "GIT_CONFIG_COUNT" => "5",
            "GIT_CONFIG_KEY_4" => "url.file://#{catalog_repo}/.insteadOf",
            "GIT_CONFIG_VALUE_4" => "https://github.com/ivankuznetsov/honeycomb.git"
          }
          MODULES.each do |name|
            version = @catalog_manifests.fetch(name).fetch("version")
            manifest = YAML.safe_load(File.binread(File.join(catalog_repo, "modules", name, version, "manifest.yml")))
            choices = install_choices(manifest)
            source = "honeycomb/#{name}@#{manifest.fetch('version')}"
            preview = JSON.parse(
              hive([ "module", "install", source, "--dry-run", "--json", *choices ],
                   env: rewrite).stdout
            )
            validate_lifecycle!(preview, name:, statuses: [ "preview" ])
            unless preview["preview_receipt"].to_s.match?(/\A[0-9]+\.[0-9a-f]{64}\z/) &&
                   preview["configuration_digest"].to_s.match?(/\A[0-9a-f]{64}\z/)
              raise Error, "#{name} module preview identity is malformed"
            end
            expected = {
              "version" => version, "catalog_commit" => @catalog_commit,
              "source_commit" => @catalog_manifests.fetch(name).fetch("source_sha"),
              "manifest_digest" => @catalog_manifests.fetch(name).fetch("manifest_sha256"),
              "configuration_digest" => preview.fetch("configuration_digest")
            }
            apply = JSON.parse(
              hive([ "module", "install", source, "--yes", "--receipt",
                     preview.fetch("preview_receipt"), "--json", *choices ],
                   env: rewrite).stdout
            )
            validate_lifecycle!(apply, name:, statuses: %w[installed already_current])
            validate_generation!(apply.dig("selection", "active"), expected, name:)
            inspected = JSON.parse(hive([ "module", "inspect", name, "--json" ]).stdout)
            validate_inspection!(inspected, name:, expected:)
          end
        end

        def validate_lifecycle!(payload, name:, statuses:)
          valid = payload.is_a?(Hash) &&
            payload["schema"] == "hive-module-lifecycle" &&
            payload["schema_version"] == 1 && payload["ok"] == true &&
            payload["operation"] == "install" && payload["name"] == name &&
            statuses.include?(payload["status"])
          raise Error, "#{name} module lifecycle response is malformed" unless valid
        end

        def validate_generation!(generation, expected, name:)
          unless generation.is_a?(Hash) && generation.keys.sort == expected.keys.sort &&
                 generation == expected
            raise Error, "#{name} installed generation differs from the exact catalogue"
          end
        end

        def validate_inspection!(payload, name:, expected:)
          valid = payload.is_a?(Hash) && payload.keys.sort == %w[modules ok schema schema_version] &&
            payload["schema"] == "hive-module-status" && payload["schema_version"] == 1 &&
            payload["ok"] == true && payload["modules"].is_a?(Array) && payload["modules"].one?
          status = payload.dig("modules", 0)
          valid &&= status.is_a?(Hash) && status["name"] == name &&
            status["lifecycle_state"] == "active" && status["installed"] == true &&
            status["enabled"] == true && status["failure_reason"].nil? &&
            status["integrity"] == {
              "configuration_valid" => true, "generation_present" => true,
              "activation_fenced" => false, "journal_present" => false
            }
          raise Error, "#{name} installed selection is unavailable" unless valid

          validate_generation!(status.fetch("active"), expected, name:)
        end

        def install_choices(manifest)
          settings = manifest.fetch("settings").flat_map do |item|
            [ "--setting", "#{item.fetch('name')}=#{item.fetch('default')}" ]
          end
          hooks = manifest.fetch("hooks").flat_map do |item|
            enabled = item.fetch("id").start_with?("scheduled-") || item.fetch("default_enabled")
            [ "--hook", "#{item.fetch('id')}=#{enabled ? 'enabled' : 'disabled'}" ]
          end
          grants = manifest.fetch("permissions").flat_map do |key, value|
            values = value.is_a?(Array) ? value : [ value ]
            values.map { |item| [ "--grant", "#{key}=#{item}" ] }
          end
          settings + hooks + grants.flatten
        end

        def collect_receipts(catalog, candidate)
          reader = ObservationReader.new(project_root: @project_root,
                                         observations_path: @observations_path,
                                         catalog: catalog, deadline: @deadline)
          catalog_digest = Digest::SHA256.hexdigest(catalog.bytes)
          common = {
            "run_id" => "u3br-#{candidate.fetch('sha')[0, 12]}",
            "candidate_sha" => candidate.fetch("sha"),
            "catalog_digest" => catalog_digest,
            "source_digest" => candidate.fetch("archive_sha256"),
            "manifest_digest" => Digest::SHA256.hexdigest(MODULES.map { |name|
              File.binread(File.join(candidate.fetch("root"), "modules", name, "manifest.yml"))
            }.join("\0")),
            "scenario_manifest_digest" => Digest::SHA256.hexdigest(catalog.bytes + "\0" + reader.bytes),
            "artifacts" => [
              { "kind" => "candidate_archive", "digest" => candidate.fetch("archive_sha256") },
              { "kind" => "scenario_catalog", "digest" => catalog_digest }
            ],
            "reviewer" => "hive-e2e/u3br"
          }
          generated_at = Time.now.utc.iso8601(6)
          prepared = []
          case_results = []
          reader.each do |case_row, observation, record|
            expected = expected_receipt(common, case_row, observation, record, generated_at)
            request = { "selector" => { "module" => case_row.module_name,
                                        "trigger_id" => observation.fetch("trigger_id") },
                        "metadata" => expected.reject { |key, _| %w[receipt_id capture module_projection effects].include?(key) } }
            request.fetch("metadata").delete("schema")
            request.fetch("metadata").delete("schema_version")
            observed = JSON.parse(hive([ "module", "migration", "deterministic-receipt", "--json" ],
                                       stdin_data: JSON.generate(request)).stdout)
            raise Error, "#{case_row.id} public receipt differs from the read-only control" unless
              PatrolQualification.canonical(observed) == PatrolQualification.canonical(expected)
            prepared << [ expected, expected_bindings(expected) ]
            case_results << {
              "id" => case_row.id, "module" => case_row.module_name,
              "fault" => case_row.fault,
              "process_outcomes" => observation.fetch("process_outcomes")
            }
          end
          { "receipts" => prepared.map(&:first), "bindings" => prepared.map(&:last),
            "case_results" => case_results.sort_by { |row| row.fetch("id") },
            "common" => common, "generated_at" => generated_at }
        end

        def expected_receipt(common, case_row, observation, record, generated_at)
          capture = record.fetch("legacy_capture")
          effects = (record.fetch("legacy_effects") + record.fetch("module_effects"))
                    .sort_by { |effect| effect.fetch("receipt_id") }
          repository = { "id" => capture.dig("project", "repository"),
                         "sha" => observation.fetch("repository_sha"),
                         "change_window" => observation.fetch("change_window") }
          payload = common.merge(
            "schema" => "hive-patrol-evidence-receipt", "schema_version" => 1,
            "configuration_digest" => record.fetch("configuration_digest"),
            "repository" => repository, "capture" => capture,
            "module_projection" => record.fetch("module_decision"),
            "decision_class" => case_row.decision_class, "effects" => effects,
            "fault_steps" => case_row.fault == "none" ? [] : [ case_row.fault ],
            "generated_at" => generated_at, "reviewed_at" => generated_at
          )
          payload.merge("receipt_id" => "evidence-#{Digest::SHA256.hexdigest(PatrolQualification.canonical(payload))}")
        end

        def expected_bindings(document)
          capture = document.fetch("capture")
          projection = document.fetch("module_projection")
          document.slice(
            "run_id", "candidate_sha", "catalog_digest", "source_digest", "manifest_digest",
            "configuration_digest", "scenario_manifest_digest", "repository", "receipt_id",
            "decision_class", "fault_steps", "artifacts", "reviewer", "generated_at", "reviewed_at"
          ).merge(
            "capture_id" => capture.fetch("capture_id"),
            "trigger_id" => capture.dig("trigger", "id"),
            "owner_epoch" => capture.fetch("owner_epoch"),
            "module_projection_digest" => Digest::SHA256.hexdigest(PatrolQualification.canonical(projection)),
            "effect_receipt_ids" => document.fetch("effects").map { |effect| effect.fetch("receipt_id") }
          )
        end

        def admit_qualification(prepared)
          report_path = File.join(state_path, "module-runtime", "migration", "report.json")
          report_before = read_report(report_path)
          request = {
            "expected_bindings" => prepared.fetch("bindings"),
            "expected_report_digest" => Digest::SHA256.hexdigest(report_before),
            "generated_at" => prepared.fetch("generated_at"),
            "receipts" => prepared.fetch("receipts")
          }
          report = JSON.parse(
            hive([ "module", "migration", "deterministic-qualification", "--yes", "--json" ],
                 stdin_data: JSON.generate(request)).stdout
          )
          report_after = read_report(report_path)
          unless report_after == PatrolQualification.canonical(report)
            raise Error, "deterministic qualification response differs from the persisted report"
          end
          report
        end

        def read_report(path)
          PatrolQualification.bounded_read(
            path, label: "qualification report", deadline: @deadline
          )
        end

        def proof(candidate, catalog, report, prepared)
          validate_qualification_report!(report, candidate:, catalog:, prepared:)
          lane = report.fetch("lanes").fetch("deterministic")
          raise Error, "reduced deterministic evidence did not qualify" unless lane.fetch("status") == "qualified"
          MODULES.each do |name|
            expected = catalog.expectations.fetch(name).fetch("decision_count")
            raise Error, "qualified #{name} decision count differs" unless
              lane.dig("modules", name, "decision_count") == expected
          end
          case_results = prepared.fetch("case_results").sort_by { |row| row.fetch("id") }
          unless case_results.map { |row| row.fetch("id") } == catalog.cases.map(&:id).sort
            raise Error, "retained case results differ from the qualification catalogue"
          end
          {
            "schema" => "hive-patrol-reduced-qualification-proof", "schema_version" => 1,
            "status" => "qualified_smoke", "candidate_sha" => candidate.fetch("sha"),
            "archive_sha256" => candidate.fetch("archive_sha256"), "gem_sha256" => candidate.fetch("gem_sha256"),
            "installed_hive_sha256" => candidate.fetch("installed_hive_sha256"),
            "catalog_commit" => @catalog_commit, "receipt_count" => prepared.fetch("receipts").size,
            "e2e_case_count" => catalog.cases.size,
            "focused_contract_count" => catalog.contracts.size,
            "case_results" => case_results,
            "qualification_id" => lane.fetch("qualification_id"),
            "claim_fences" => [
              "not_full_u3b", "not_u3c_installed_live", "same_candidate_controls_not_independent",
              "prepared_records_not_fresh_scheduler_matrix"
            ]
          }
        end

        def validate_qualification_report!(report, candidate:, catalog:, prepared:)
          keys = %w[
            blockers candidate_sha generated_at lanes migration report_id
            scenario_manifest_digest schema schema_version status supersedes
          ]
          common = prepared.fetch("common")
          valid = report.is_a?(Hash) && report.keys.sort == keys.sort &&
            report["schema"] == "hive-module-migration-report" &&
            report["schema_version"] == 2 && report["candidate_sha"] == candidate.fetch("sha") &&
            report["scenario_manifest_digest"] == common.fetch("scenario_manifest_digest") &&
            %w[evidence_required qualified].include?(report["status"]) &&
            report["blockers"].is_a?(Array) &&
            report["lanes"].is_a?(Hash) && report["lanes"].keys.sort == %w[deterministic installed_live]
          raise Error, "deterministic qualification report is malformed" unless valid

          lane = report.dig("lanes", "deterministic")
          lane_keys = %w[
            blockers candidate_sha catalog_digest contradiction decision_replay_count
            duplicate_effects effect_count effect_replay_count elapsed_seconds
            evidence_started_at generated_at lane manifest_digest modules qualification_id
            receipt_ids run_id scenario_manifest_digest source_digest status supersedes
            unsettled_effects
          ]
          receipt_ids = prepared.fetch("receipts").map { |receipt| receipt.fetch("receipt_id") }.sort
          valid = lane.is_a?(Hash) && lane.keys.sort == lane_keys.sort &&
            lane["lane"] == "deterministic" && lane["status"] == "qualified" &&
            lane["run_id"] == common.fetch("run_id") &&
            lane["candidate_sha"] == candidate.fetch("sha") &&
            lane["catalog_digest"] == common.fetch("catalog_digest") &&
            lane["source_digest"] == common.fetch("source_digest") &&
            lane["manifest_digest"] == common.fetch("manifest_digest") &&
            lane["scenario_manifest_digest"] == common.fetch("scenario_manifest_digest") &&
            receipt_ids.uniq.size == receipt_ids.size && lane["receipt_ids"] == receipt_ids &&
            lane["modules"].is_a?(Hash) && lane["modules"].keys.sort == MODULES.sort &&
            lane["blockers"] == [] &&
            lane["duplicate_effects"] == [] && lane["unsettled_effects"] == []
          raise Error, "deterministic qualification lane differs from this campaign" unless valid

          MODULES.each do |name|
            receipts = prepared.fetch("receipts").select do |receipt|
              receipt.dig("module_projection", "module") == name
            end
            summary = lane.dig("modules", name)
            expected = catalog.expectations.fetch(name)
            summary_keys = %w[
              blockers change_windows configuration_digest decision_classes
              decision_count decision_identities elapsed_seconds repository_shas
            ]
            configurations = receipts.map { |row| row.fetch("configuration_digest") }.uniq
            valid = summary.is_a?(Hash) && summary.keys.sort == summary_keys.sort &&
              summary["decision_count"] == receipts.size &&
              summary["decision_count"] == expected.fetch("decision_count") &&
              summary["decision_identities"].is_a?(Array) &&
              summary["decision_identities"].size == receipts.size &&
              summary["decision_identities"].uniq.size == receipts.size &&
              summary["decision_identities"].all? { |id| id.to_s.match?(/\Adecision-[0-9a-f]{64}\z/) } &&
              summary["decision_classes"] == receipts.map { |row| row.fetch("decision_class") }.uniq.sort &&
              summary["repository_shas"] == receipts.map { |row| row.dig("repository", "sha") }.uniq.sort &&
              summary["change_windows"] == receipts.map { |row| row.dig("repository", "change_window") }.uniq.sort &&
              configurations.one? && summary["configuration_digest"] == configurations.first &&
              summary["blockers"] == []
            raise Error, "qualified #{name} summary differs from this campaign" unless valid
          end

          qualification_id = "qualification-#{Digest::SHA256.hexdigest(
            PatrolQualification.canonical(lane.reject { |key, _| key == "qualification_id" })
          )}"
          report_id = "report-#{Digest::SHA256.hexdigest(
            PatrolQualification.canonical(report.reject { |key, _| key == "report_id" })
          )}"
          unless lane["qualification_id"] == qualification_id && report["report_id"] == report_id
            raise Error, "deterministic qualification identity differs from its contents"
          end
        end

        def write_evidence(value)
          redacted = redact(value)
          bytes = PatrolQualification.canonical(redacted)
          raise Error, "qualification evidence exceeds its bound" if bytes.bytesize > MAX_EVIDENCE_BYTES
          if Hive::SecretPatterns.scan(bytes).any?
            raise Error, "qualification evidence contains a secret pattern"
          end
          FileUtils.mkdir_p(@evidence_root, mode: 0o700)
          path = File.join(@evidence_root, "patrol-u3br-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{Process.pid}.json")
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
          path
        end

        def redact(value)
          case value
          when Hash
            value.to_h do |key, child|
              redacted_key = Hive::SecretPatterns.redact(key.to_s)
              redacted_child = if key.to_s.match?(/token|secret|password|credential/i)
                "[REDACTED]"
              else
                redact(child)
              end
              [ redacted_key, redacted_child ]
            end
          when Array then value.map { |child| redact(child) }
          when String then Hive::SecretPatterns.redact(value)
          else value
          end
        end

        def state_path
          config = YAML.safe_load(PatrolQualification.bounded_read(
            File.join(@project_root, ".hive-state", "config.yml"),
            label: "qualification project config", deadline: @deadline
          )) || {}
          File.expand_path(config.fetch("hive_state_path", ".hive-state"), @project_root)
        end

        def hive(args, stdin_data: "", env: {})
          run(@hive_bin, *args, cwd: @project_root, stdin_data: stdin_data, env: env,
              label: "installed hive #{args.first(3).join(' ')}")
        end

        def run(*command, label:, cwd: @repo_root, stdin_data: "", env: {})
          process = env.empty? ? @process : ChildProcess.new(deadline: @deadline, env: @env.merge(env))
          process.run(*command, label: label, cwd: cwd, stdin_data: stdin_data, timeout: @child_timeout)
        end

        def git(*arguments, **options)
          run("git", *GIT_OVERRIDES, *arguments, **options)
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
