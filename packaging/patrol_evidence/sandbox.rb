# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "timeout"
require_relative "result"

module HivePatrolEvidence
  # Owns the one fixed, networkless container used by the candidate smoke.
  class Sandbox
    class Error < StandardError
      attr_reader :reason, :status, :process_evidence

      def initialize(reason, message = reason, status: "failed", process_evidence: nil)
        @reason = reason
        @status = status
        @process_evidence = process_evidence
        super(message)
      end

      def with_process_evidence(value)
        self.class.new(reason, message, status:, process_evidence: value)
      end
    end

    IMAGE = /\A[a-z0-9][a-z0-9._\/-]*@sha256:[0-9a-f]{64}\z/
    SHA = /\A[0-9a-f]{40}\z/
    DIGEST = /\A[0-9a-f]{64}\z/
    MAX_STDOUT_BYTES = 1024 * 1024
    MAX_STDERR_BYTES = 1024 * 1024
    CAMPAIGN_TIMEOUT = 600
    PROCESS_LIMIT = 64
    MEMORY = "2g"
    CPUS = "2"
    WRITABLE_BYTES = 512 * 1024 * 1024
    WRITABLE_INODES = 16_384
    SHM_BYTES = 1024 * 1024
    SHM_INODES = 128
    STATE_BYTES = WRITABLE_BYTES - SHM_BYTES
    STATE_INODES = WRITABLE_INODES - SHM_INODES
    ENGINE_COMMAND_TIMEOUT = 10
    ENGINE_PATHS = %w[/usr/bin/podman /usr/local/bin/podman /usr/bin/docker /usr/local/bin/docker].freeze
    ENGINE_ENV = {
      "HOME" => "/nonexistent", "PATH" => "/usr/bin:/bin", "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8"
    }.freeze
    WORKER = <<~'RUBY'.freeze
      require "fileutils"
      require "find"
      require "json"
      root = "/state/candidate"
      project = "/state/project"
      FileUtils.mkdir_p(project)
      FileUtils.mkdir_p("/state/home")
      FileUtils.cp_r("/input/source", root, preserve: true)
      Find.find(root) do |path|
        stat = File.lstat(path)
        if stat.directory? && !stat.symlink?
          File.chmod(0o700, path)
        elsif stat.file? && !stat.symlink?
          File.chmod((stat.mode & 0o111).zero? ? 0o600 : 0o700, path)
        else
          raise "candidate build copy contains a special entry"
        end
      end
      FileUtils.cp_r("/input/project/.", project, preserve: true)
      controller = Hive::E2E::PatrolQualification::Controller.new(
        repo_root: root, project_root: project, hive_home: "/state/home",
        observations_path: "/input/observations.json", evidence_root: "/state/evidence"
      )
      result = controller.external_smoke(
        controller_sha: ENV.fetch("HIVE_PATROL_CONTROLLER_SHA"),
        candidate_sha: ENV.fetch("HIVE_PATROL_CANDIDATE_SHA"),
        candidate: {
          "candidate_sha" => ENV.fetch("HIVE_PATROL_CANDIDATE_SHA"),
          "archive_sha256" => ENV.fetch("HIVE_PATROL_ARCHIVE_SHA256"),
          "module_manifest_sha256" => ENV.fetch("HIVE_PATROL_MODULE_MANIFEST_SHA256"),
          "source_root" => "/input/source",
          "source_tree_sha256" => ENV.fetch("HIVE_PATROL_SOURCE_TREE_SHA256")
        },
        trusted_catalog_path: "/input/catalog.json", worker: true
      )
      STDOUT.write(Hive::E2E::PatrolQualification.canonical(result))
    RUBY

    def initialize(image:, engine_probe: nil, executor: nil, timeout: CAMPAIGN_TIMEOUT)
      @image = image.to_s
      @engine_probe = engine_probe || method(:probe_engine)
      @executor = executor || method(:execute_container)
      @timeout = Float(timeout)
      raise Error.new("sandbox_contract", "sandbox image is not digest-pinned") unless IMAGE.match?(@image)
      raise Error.new("sandbox_contract", "sandbox timeout is invalid") unless
        @timeout.positive? && @timeout <= CAMPAIGN_TIMEOUT
    rescue ArgumentError, TypeError
      raise Error.new("sandbox_contract", "sandbox inputs are invalid"), cause: nil
    end

    def run!(candidate:, project_root:, observations_path:, controller_root:, run_root:, image:)
      raw = nil
      raise Error.new("sandbox_contract", "sandbox image binding changed") unless image.to_s == @image
      inputs = admit_inputs(candidate, project_root, observations_path, controller_root, run_root)
      before = admit_engine_identity(@engine_probe.call)
      argv, name, cidfile, owner_label = command(before, inputs)
      raw = @executor.call(
        argv:, timeout: @timeout, name:, engine: before.fetch("engine_path"), cidfile:, owner_label:
      )
      after = admit_engine_identity(@engine_probe.call)
      raise Error.new("runtime_identity", "container runtime identity drifted") unless before == after
      payload = admit_output(raw)
      sandbox = before.reject { |key, _| key == "engine_path" }.merge(
        "status" => "passed", "network" => "none", "root_filesystem" => "read_only",
        "writable_bytes" => WRITABLE_BYTES, "writable_inodes" => WRITABLE_INODES,
        "process_limit" => PROCESS_LIMIT, "memory" => MEMORY, "cpus" => CPUS
      )
      payload.merge("sandbox" => sandbox.freeze).freeze
    rescue Error => error
      evidence = raw.is_a?(Hash) && raw["process_evidence"].is_a?(Array) ? raw["process_evidence"] : nil
      raise error if error.process_evidence || !evidence

      raise error.with_process_evidence(evidence)
    rescue StandardError
      evidence = raw.is_a?(Hash) && raw["process_evidence"].is_a?(Array) ? raw["process_evidence"] : nil
      raise Error.new(
        "sandbox_contract", "sandbox execution failed", process_evidence: evidence
      ), cause: nil
    end

    private

    def admit_inputs(candidate, project_root, observations_path, controller_root, run_root)
      unless candidate.is_a?(Hash) && candidate.fetch("controller_sha").to_s.match?(SHA) &&
             candidate.fetch("candidate_sha").to_s.match?(SHA) &&
             candidate.fetch("controller_sha") != candidate.fetch("candidate_sha") &&
             candidate.fetch("archive_sha256").to_s.match?(DIGEST) &&
             candidate.fetch("module_manifest_sha256").to_s.match?(DIGEST) &&
             candidate.fetch("source_tree_sha256").to_s.match?(DIGEST)
        raise Error.new("sandbox_contract", "candidate sandbox binding is malformed")
      end
      archive = regular_file!(candidate.fetch("archive_path"), "candidate archive", 256 * 1024 * 1024)
      unless Digest::SHA256.file(archive).hexdigest == candidate.fetch("archive_sha256")
        raise Error.new("candidate_identity", "candidate archive changed before sandbox execution")
      end
      source = owned_directory!(candidate.fetch("source_path"), "admitted candidate source")
      controller = owned_directory!(controller_root, "controller root")
      catalog = regular_file!(
        File.join(controller, "test/e2e/fixtures/patrol_qualification/catalog.json"),
        "trusted qualification catalogue", 1024 * 1024
      )
      controller_script = regular_file!(
        File.join(controller, "test/e2e/lib/patrol_qualification.rb"),
        "trusted qualification controller", 1024 * 1024
      )
      controller_support = regular_file!(
        File.join(controller, "lib/hive/secret_patterns.rb"),
        "trusted controller support", 1024 * 1024
      )
      {
        candidate:, archive:, source:, project: owned_directory!(project_root, "disposable project"),
        observations: regular_file!(observations_path, "prepared observations", 8 * 1024 * 1024),
        catalog:, controller_script:, controller_support:,
        run_root: owned_directory!(run_root, "sandbox run root")
      }
    rescue KeyError, TypeError
      raise Error.new("sandbox_contract", "sandbox inputs are malformed"), cause: nil
    end

    def command(identity, inputs)
      candidate = inputs.fetch(:candidate)
      run_identity = File.basename(inputs.fetch(:run_root))
      name_digest = Digest::SHA256.hexdigest(
        [ candidate.fetch("candidate_sha"), run_identity ].join("\0")
      )[0, 20]
      name = "hive-patrol-u3c-#{name_digest}"
      cidfile = File.join(inputs.fetch(:run_root), "container.cid")
      begin
        File.lstat(cidfile)
        raise Error.new("path_custody", "sandbox container identifier path already exists")
      rescue Errno::ENOENT
        nil
      end
      state = [
        "--tmpfs=/state:rw,nosuid,nodev,size=#{STATE_BYTES},nr_inodes=#{STATE_INODES}",
        "uid=#{Process.uid},gid=#{Process.gid},mode=0700"
      ].join(",")
      shared_memory = [
        "--tmpfs=/dev/shm:rw,nosuid,nodev,noexec,size=#{SHM_BYTES},nr_inodes=#{SHM_INODES}",
        "uid=#{Process.uid},gid=#{Process.gid},mode=0700"
      ].join(",")
      mounts = {
        inputs.fetch(:source) => "/input/source",
        inputs.fetch(:project) => "/input/project",
        inputs.fetch(:observations) => "/input/observations.json",
        inputs.fetch(:catalog) => "/input/catalog.json",
        inputs.fetch(:controller_script) => "/control/test/e2e/lib/patrol_qualification.rb",
        inputs.fetch(:controller_support) => "/control/lib/hive/secret_patterns.rb"
      }.flat_map do |source, target|
        [ "--mount", "type=bind,source=#{source},target=#{target},readonly" ]
      end
      argv = [
        identity.fetch("engine_path"), "run", "--name", name, "--rm", "--pull=never",
        "--cidfile=#{cidfile}",
        "--label=hive.patrol.owner=#{Digest::SHA256.hexdigest(run_identity)}",
        "--network=none", "--read-only", "--cap-drop=ALL",
        "--security-opt", "no-new-privileges", "--pids-limit=#{PROCESS_LIMIT}",
        "--memory=#{MEMORY}", "--cpus=#{CPUS}", "--stop-timeout=1",
        "--user=#{Process.uid}:#{Process.gid}", state, shared_memory, *mounts,
        "--env", "HOME=/state/home", "--env", "HIVE_HOME=/state/home",
        "--env", "LANG=C.UTF-8", "--env", "LC_ALL=C.UTF-8",
        "--env", "HIVE_SKIP_LLM_WIKI_SCHEDULER=1",
        "--env", "HIVE_SKIP_LLM_WIKI_SYSTEMCTL=1",
        "--env", "HIVE_SKIP_LLM_WIKI_POST_COMMIT=1",
        "--env", "HIVE_PATROL_CONTROLLER_SHA=#{candidate.fetch('controller_sha')}",
        "--env", "HIVE_PATROL_CANDIDATE_SHA=#{candidate.fetch('candidate_sha')}",
        "--env", "HIVE_PATROL_ARCHIVE_SHA256=#{candidate.fetch('archive_sha256')}",
        "--env", "HIVE_PATROL_MODULE_MANIFEST_SHA256=#{candidate.fetch('module_manifest_sha256')}",
        "--env", "HIVE_PATROL_SOURCE_TREE_SHA256=#{candidate.fetch('source_tree_sha256')}",
        @image, "/usr/local/bin/ruby",
        "-r/control/test/e2e/lib/patrol_qualification", "-e", WORKER
      ]
      [ argv.freeze, name.freeze, cidfile.freeze, Digest::SHA256.hexdigest(run_identity).freeze ]
    end

    def admit_engine_identity(value)
      valid = value.is_a?(Hash) && value.keys.sort == %w[
        engine engine_path engine_sha256 engine_version image image_id
      ] &&
        %w[docker podman].include?(value["engine"]) &&
        File.basename(value.fetch("engine_path")) == value.fetch("engine") &&
        value.fetch("engine_sha256").to_s.match?(DIGEST) &&
        value["engine_version"].is_a?(String) && !value["engine_version"].empty? &&
        value["image"] == @image && value["image_id"].to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
      raise Error.new("sandbox_unavailable", "compliant sandbox is unavailable", status: "blocked") unless valid
      value.transform_values { |item| item.is_a?(String) ? item.dup.freeze : item }.freeze
    end

    def admit_output(value)
      unless value.is_a?(Hash) && value.keys.sort == %w[candidate payload process_evidence] &&
             value["candidate"].is_a?(Hash) && value["payload"].is_a?(Hash) &&
             value["process_evidence"].is_a?(Array) && value["process_evidence"].one? &&
             valid_success_process?(value.fetch("process_evidence").fetch(0))
        raise Error.new("process_custody", "sandbox result or process custody is malformed")
      end
      bytes = Result.canonical(value)
      raise Error.new("output_bound", "sandbox output exceeds its bound") if bytes.bytesize > MAX_STDOUT_BYTES
      raise Error.new("credential_custody", "sandbox output contains credential-shaped bytes") if
        Hive::SecretPatterns.match?(bytes)
      value
    end

    def valid_success_process?(row)
      row.is_a?(Hash) && row.keys.sort == Result::PROCESS_KEYS &&
        row.values_at("owner", "status", "outcome", "teardown", "exit_code") ==
          [ "sandbox", "reaped", "success", "verified", 0 ] &&
        %w[container_id_sha256 stdout_sha256 stderr_sha256].all? do |key|
          row.fetch(key).to_s.match?(DIGEST)
        end
    rescue KeyError, TypeError
      false
    end

    def execute_container(argv:, timeout:, name:, engine:, cidfile:, owner_label:)
      stdout = +""
      stderr = +""
      status = nil
      pid = nil
      readers = []
      container_id = nil
      payload = nil
      outcome = "unavailable"
      teardown = "unverified"
      error = nil
      begin
        Open3.popen3(ENGINE_ENV, *argv, unsetenv_others: true, pgroup: true) do |input, out, err, wait|
          pid = wait.pid
          input.close
          readers = [ out, err ].zip([ stdout, stderr ], [ MAX_STDOUT_BYTES, MAX_STDERR_BYTES ]).map do |io, destination, limit|
            Thread.new { read_bounded(io, destination, limit) }.tap { |thread| thread.report_on_exception = false }
          end
          unless wait.join(timeout)
            container_id = read_container_id!(cidfile, required: false)
            capture_engine(engine, "kill", container_id) if container_id
            terminate_group(pid)
            outcome = "timeout"
            raise Error.new("process_custody", "sandbox campaign timed out")
          end
          status = wait.value
          readers.each { |thread| thread.join(1) }
          raise Error.new("output_bound", "sandbox output did not close") if readers.any?(&:alive?)
          readers.each(&:value)
        end
        container_id = read_container_id!(cidfile, required: true)
        outcome = status&.success? ? "success" : "failed"
        raise Error.new("sandbox_contract", "sandbox candidate command failed") unless status&.success?
        payload = JSON.parse(stdout)
        unless Result.canonical(payload) == stdout
          raise Error.new("sandbox_contract", "sandbox result is not canonical")
        end
      rescue JSON::ParserError
        error = Error.new("sandbox_contract", "sandbox result is malformed")
      rescue Error => caught
        error = caught
      rescue SystemCallError
        error = Error.new("sandbox_unavailable", "container runtime is unavailable", status: "blocked")
      ensure
        terminate_group(pid) if pid && !status
        readers.each { |thread| thread.kill if thread.alive? }
        begin
          container_id ||= read_container_id!(cidfile, required: false)
          teardown_container!(engine, cidfile, container_id, owner_label)
          teardown = "verified"
        rescue Error => teardown_error
          error = teardown_error
          teardown = "unverified"
        end
      end
      evidence = [ {
        "owner" => "sandbox",
        "status" => teardown == "verified" ? "reaped" : "not_reaped",
        "outcome" => outcome,
        "teardown" => teardown,
        "exit_code" => status&.exitstatus,
        "container_id_sha256" => container_id && Digest::SHA256.hexdigest(container_id),
        "stdout_sha256" => Digest::SHA256.hexdigest(stdout),
        "stderr_sha256" => Digest::SHA256.hexdigest(stderr)
      }.freeze ].freeze
      raise error.with_process_evidence(evidence) if error

      payload.merge("process_evidence" => evidence)
    end

    def teardown_container!(engine, cidfile, container_id, owner_label)
      unless container_id
        remove_container_id!(cidfile)
        return true
      end
      label, _label_err, inspected = capture_engine(
        engine, "container", "inspect", "--format", "{{ index .Config.Labels \"hive.patrol.owner\" }}",
        container_id
      )
      if inspected.success?
        unless label.strip == owner_label
          raise Error.new("process_custody", "sandbox container ownership label differs")
        end
        _out, _err, removed = capture_engine(engine, "rm", "-f", container_id)
        raise Error.new("process_custody", "sandbox container teardown failed") unless removed.success?
      else
        verify_engine_reachable!(engine)
      end
      _out, _err, survived = capture_engine(engine, "container", "inspect", container_id)
      raise Error.new("process_custody", "sandbox container survived teardown") if survived.success?
      verify_engine_reachable!(engine)
      remove_container_id!(cidfile)
      true
    rescue Error
      raise
    rescue SystemCallError
      raise Error.new("process_custody", "sandbox teardown could not be verified"), cause: nil
    end

    def verify_engine_reachable!(engine)
      _out, _err, status = capture_engine(engine, "info")
      raise Error.new("process_custody", "container runtime teardown could not be verified") unless status.success?
    end

    def read_container_id!(path, required:)
      File.open(path, File::RDONLY | (File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0)) do |file|
        stat = file.stat
        value = file.read(66)
        unless stat.file? && stat.nlink == 1 && stat.uid == Process.uid && stat.size <= 65 &&
               value.match?(/\A[0-9a-f]{64}\n?\z/)
          raise Error.new("process_custody", "sandbox container identifier is unsafe")
        end
        value.strip
      end
    rescue Errno::ENOENT
      raise Error.new("process_custody", "sandbox container identifier is missing") if required
      nil
    rescue Errno::ELOOP, Errno::EACCES
      raise Error.new("process_custody", "sandbox container identifier is unsafe"), cause: nil
    end

    def remove_container_id!(path)
      return unless File.exist?(path)

      stat = File.lstat(path)
      read_container_id!(path, required: true)
      current = File.lstat(path)
      unless %i[dev ino uid mode nlink].all? { |field| current.public_send(field) == stat.public_send(field) }
        raise Error.new("process_custody", "sandbox container identifier changed during teardown")
      end
      File.unlink(path)
      File.open(File.dirname(path), File::RDONLY) { |directory| directory.fsync }
    rescue Errno::ENOENT
      nil
    end

    def probe_engine
      ENGINE_PATHS.each do |candidate|
        next unless File.file?(candidate) && File.executable?(candidate)
        engine = File.realpath(candidate)
        stat = File.lstat(engine)
        next unless stat.file? && !stat.symlink?
        version, _version_err, version_status = capture_engine(engine, "--version")
        next unless version_status.success?
        _info, _info_err, info_status = capture_engine(engine, "info")
        next unless info_status.success?
        image_id, _image_err, image_status = capture_engine(
          engine, "image", "inspect", "--format", "{{.Id}}", @image
        )
        next unless image_status.success?
        return {
          "engine" => File.basename(engine), "engine_path" => engine,
          "engine_sha256" => Digest::SHA256.file(engine).hexdigest,
          "engine_version" => version.lines.first.to_s.strip,
          "image" => @image, "image_id" => image_id.strip
        }
      rescue SystemCallError, Error
        next
      end
      nil
    end

    def capture_engine(engine, *arguments)
      stdout = +""
      stderr = +""
      wait_status = nil
      pid = nil
      readers = []
      Open3.popen3(ENGINE_ENV, engine, *arguments, unsetenv_others: true, pgroup: true) do |input, out, err, wait|
        pid = wait.pid
        input.close
        readers = [ [ out, stdout ], [ err, stderr ] ].map do |io, destination|
          Thread.new { read_bounded(io, destination, 64 * 1024) }.tap { |thread| thread.report_on_exception = false }
        end
        unless wait.join(ENGINE_COMMAND_TIMEOUT)
          terminate_group(pid)
          raise Error.new("process_custody", "container runtime command timed out")
        end
        wait_status = wait.value
        readers.each { |thread| thread.join(1) }
        raise Error.new("output_bound", "container runtime output did not close") if readers.any?(&:alive?)
        readers.each(&:value)
      end
      [ stdout, stderr, wait_status ]
    ensure
      terminate_group(pid) if pid && !wait_status
      readers.each { |thread| thread.kill if thread.alive? }
    end

    def read_bounded(io, destination, limit)
      while (chunk = io.read(16 * 1024))
        remaining = limit - destination.bytesize
        raise Error.new("output_bound", "sandbox child output exceeds its bound") if
          chunk.bytesize > remaining
        destination << chunk
      end
    ensure
      io.close rescue nil
    end

    def terminate_group(pid)
      Process.kill("TERM", -pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        begin
          Process.kill(0, -pid)
        rescue Errno::ESRCH
          return
        end
        sleep 0.02
      end
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def owned_directory!(path, label)
      absolute = File.expand_path(path)
      stat = File.lstat(absolute)
      unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
        raise Error.new("path_custody", "#{label} is not an owned directory")
      end
      absolute
    rescue Errno::ENOENT, Errno::EACCES
      raise Error.new("path_custody", "#{label} is unavailable")
    end

    def regular_file!(path, label, limit)
      absolute = File.expand_path(path)
      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      File.open(absolute, flags) do |file|
        stat = file.stat
        unless stat.file? && stat.nlink == 1 && stat.uid == Process.uid && stat.size.between?(1, limit)
          raise Error.new("path_custody", "#{label} is unsafe")
        end
      end
      absolute
    rescue Errno::ELOOP, Errno::ENOENT, Errno::EACCES
      raise Error.new("path_custody", "#{label} is unavailable")
    end
  end
end
