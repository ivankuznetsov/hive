require "json"
require "hive/atomic_file"

module Hive
  module Attempts
    # Tags and removes the rootless Podman containers one durable attempt
    # starts. ScopeReaper cannot reach them: with the systemd cgroup manager
    # the container runs in `libpod-<id>.scope` and conmon in
    # `libpod-conmon-<id>.scope`, both outside the `hive-attempt-*.scope`, so
    # an agent's test database outlived its attempt by days.
    #
    # Tagging: the supervisor writes a containers.conf fragment into the
    # attempt's private output directory and points the worker at it with
    # CONTAINERS_CONF_OVERRIDE. Podman loads that file last, after the system
    # and user files and after a CONTAINERS_CONF an agent sets itself, and the
    # `{append=true}` attribute adds Hive's annotations to any the operator or
    # agent already configured instead of replacing them. Every `podman run`
    # or `podman create` in the attempt then carries `hive.attempt=<id>` and
    # `hive.project=<name>`.
    #
    # An inherited CONTAINERS_CONF_OVERRIDE (the operator's own) is never
    # replaced: Podman reads only one override file and TOML fragments cannot
    # include each other, so Hive skips tagging and records `untagged`.
    #
    # Reaping: `podman ps --all --filter annotation=hive.attempt=<id>`, then
    # `podman rm --force --volumes`. `--volumes` removes only the anonymous
    # volumes those containers created (an image VOLUME such as Postgres's
    # data directory); named volumes are never removed by `podman rm`, which
    # is how a project keeps data across containers on purpose. Every Podman
    # call shares one deadline and runs in its own process group, so a hung
    # Podman is killed rather than holding the attempt open. Nothing here
    # raises: a failure becomes a `failed` or `incomplete` result.
    class ContainerReaper
      ATTEMPT_ANNOTATION = "hive.attempt".freeze
      PROJECT_ANNOTATION = "hive.project".freeze
      OVERRIDE_ENV = "CONTAINERS_CONF_OVERRIDE".freeze
      CONF_DIRECTORY = "containers".freeze
      CONF_FILENAME = "containers.conf".freeze
      DEFAULT_TIMEOUT_SEC = 30.0
      MAX_STOP_SEC = 10
      MAX_CONTAINERS = 256
      OUTPUT_BYTES = 1024 * 1024
      TERMINATION_GRACE_SEC = 1.0

      Command = Data.define(:status, :output) do
        def ok? = status == :ok
      end

      Result = Data.define(:status, :annotation, :reaped, :survivors, :error) do
        # `clean`, `disabled` and `no_podman` are the expected quiet outcomes.
        def notable? = %w[reaped incomplete failed untagged].include?(status)

        def to_h
          payload = { "annotation" => annotation, "status" => status,
                      "reaped" => reaped, "survivors" => survivors }
          payload["error"] = error if error
          payload
        end

        def journal_line
          "hive-attempt: attempt_containers #{JSON.generate(to_h)}\n"
        end
      end

      Tagging = Data.define(:status, :environment, :error) do
        def tagged? = status == "tagged"
      end

      def self.annotation(attempt_id) = "#{ATTEMPT_ANNOTATION}=#{attempt_id}"

      # TOML basic strings accept JSON string escapes, so JSON.generate
      # quotes a project name safely.
      def self.conf_contents(attempt_id:, project:)
        values = [ annotation(attempt_id) ]
        values << "#{PROJECT_ANNOTATION}=#{project}" unless project.to_s.empty?
        quoted = values.map { |value| JSON.generate(value) }
        "# Written by Hive for durable attempt #{attempt_id}.\n" \
          "[containers]\nannotations = [#{quoted.join(', ')}, {append=true}]\n"
      end

      def initialize(attempt_id:, podman: nil, runner: nil, monotonic: nil, environment: ENV)
        @attempt_id = attempt_id.to_s
        @annotation = self.class.annotation(@attempt_id)
        @podman = podman || environment.fetch("HIVE_PODMAN_BIN", "podman")
        @runner = runner || method(:run_bounded)
        @monotonic = monotonic || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @environment = environment
      end

      # Returns the worker environment that tags this attempt's containers.
      def tag(directory:, project:)
        inherited = @environment[OVERRIDE_ENV].to_s
        return Tagging.new(status: "untagged", environment: {}, error: "operator_containers_conf_override") unless
          inherited.empty?

        path = File.join(directory, CONF_FILENAME)
        Hive::AtomicFile.write(path, self.class.conf_contents(attempt_id: @attempt_id, project: project), mode: 0o600)
        Tagging.new(status: "tagged", environment: { OVERRIDE_ENV => path }, error: nil)
      rescue StandardError => e
        Tagging.new(status: "untagged", environment: {}, error: "#{e.class}: #{e.message}")
      end

      def untagged_result(tagging)
        result("untagged", error: tagging.error)
      end

      def reap(timeout_sec: DEFAULT_TIMEOUT_SEC, stop_timeout_sec: MAX_STOP_SEC)
        deadline = @monotonic.call + [ timeout_sec.to_f, 0.0 ].max
        listed = list(deadline)
        return listed unless listed.is_a?(Array)
        return result("clean") if listed.empty?

        stop = stop_timeout_sec.to_f.floor.clamp(0, MAX_STOP_SEC)
        removal = @runner.call(
          [ @podman, "rm", "--force", "--volumes", "--time", stop.to_s, *listed.map { |entry| entry.fetch("id") } ],
          remaining(deadline)
        )
        after = list(deadline)
        unless after.is_a?(Array)
          return result("incomplete", survivors: listed, error: after.error || command_error("rm", removal))
        end

        remaining_ids = after.map { |entry| entry.fetch("id") }
        reaped = listed.reject { |entry| remaining_ids.include?(entry.fetch("id")) }
        return result("reaped", reaped: reaped) if after.empty?

        result("incomplete", reaped: reaped, survivors: after, error: removal.ok? ? nil : command_error("rm", removal))
      rescue StandardError => e
        result("failed", error: "#{e.class}: #{e.message}")
      end

      private

      def list(deadline)
        command = @runner.call(
          [ @podman, "ps", "--all", "--filter", "annotation=#{@annotation}", "--format", "json" ],
          remaining(deadline)
        )
        return result("no_podman") if command.status == :missing
        return result("failed", error: command_error("ps", command)) unless command.ok?

        parse_containers(command.output)
      end

      def parse_containers(output)
        text = output.to_s.strip
        entries = text.empty? ? [] : JSON.parse(text)
        raise ArgumentError, "podman ps output is not a list" unless entries.is_a?(Array)
        raise ArgumentError, "more than #{MAX_CONTAINERS} tagged containers" if entries.length > MAX_CONTAINERS

        entries.map do |entry|
          id = entry.fetch("Id").to_s
          raise ArgumentError, "podman ps returned an invalid container id" unless id.match?(/\A[0-9a-f]{12,64}\z/)

          { "id" => id, "name" => Array(entry["Names"]).first.to_s, "image" => entry["Image"].to_s,
            "state" => entry["State"].to_s }
        end
      end

      def result(status, reaped: [], survivors: [], error: nil)
        Result.new(
          status: status, annotation: @annotation,
          reaped: describe(reaped), survivors: describe(survivors), error: error
        )
      end

      # Podman's short id is enough to recognise a container in the log.
      def describe(entries)
        entries.map { |entry| entry.merge("id" => entry.fetch("id")[0, 12]) }
      end

      def command_error(verb, command)
        detail = command.output.to_s.strip.lines.last.to_s.strip.byteslice(0, 240)
        "podman #{verb} #{command.status}#{": #{detail}" unless detail.empty?}"
      end

      def remaining(deadline)
        [ deadline - @monotonic.call, 0.0 ].max
      end

      # Podman runs in its own process group with stdin closed; at the
      # deadline the whole group gets TERM, then KILL, and is reaped.
      def run_bounded(argv, timeout_sec)
        return Command.new(status: :timeout, output: "") unless timeout_sec.positive?

        reader, writer = IO.pipe
        output = +""
        pid = Process.spawn(*argv, in: File::NULL, out: writer, err: writer, pgroup: true)
        writer.close
        deadline = @monotonic.call + timeout_sec
        loop do
          drain(reader, output)
          if (waited = Process.wait2(pid, Process::WNOHANG))
            pid = nil
            drain(reader, output)
            return Command.new(status: waited.last.success? ? :ok : :failed, output: output)
          end
          left = deadline - @monotonic.call
          if left <= 0
            terminate(pid)
            pid = nil
            return Command.new(status: :timeout, output: output)
          end
          IO.select([ reader ], nil, nil, [ left, 0.05 ].min)
        end
      rescue Errno::ENOENT, Errno::EACCES
        Command.new(status: :missing, output: "")
      ensure
        writer&.close unless writer&.closed?
        reader&.close unless reader&.closed?
        terminate(pid) if pid
      end

      def drain(reader, output)
        loop do
          chunk = reader.read_nonblock(4096, exception: false)
          return if chunk == :wait_readable || chunk.nil?

          room = OUTPUT_BYTES - output.bytesize
          output << chunk.byteslice(0, room) if room.positive?
        end
      rescue IOError
        nil
      end

      def terminate(pid)
        signal_group(pid, "TERM")
        deadline = @monotonic.call + TERMINATION_GRACE_SEC
        until @monotonic.call >= deadline
          return if Process.wait2(pid, Process::WNOHANG)

          sleep 0.02
        end
        signal_group(pid, "KILL")
        Process.wait2(pid)
      rescue Errno::ECHILD
        nil
      end

      def signal_group(pid, signal)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end
  end
end
