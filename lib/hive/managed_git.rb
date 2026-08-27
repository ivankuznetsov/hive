require "open3"
require "shellwords"

module Hive
  # Hardened Git process boundary for controller work performed after a
  # managed agent has edited a repository. Repository data and local Git
  # configuration remain untrusted; fixed command-line overrides prevent
  # hooks, fsmonitor, external diff/textconv, custom transports, and arbitrary
  # credential/SSH helpers from executing in the controller process.
  module ManagedGit
    NETWORK_TIMEOUT_SEC = 60
    TERMINATION_GRACE_SEC = 0.1
    MAX_TRACKED_GITLINKS = 128
    DEFAULT_GITLINK_OUTPUT_BYTES = 64 * 1024
    GH_BIN_ENV = "HIVE_GH_BIN"
    COMMANDS = %w[
      cat-file diff fetch init ls-remote merge-base push read-tree remote
      rev-list rev-parse show status symbolic-ref update-ref worktree
    ].freeze
    CONFIG = [
      "core.hooksPath=/dev/null",
      "core.fsmonitor=false",
      "core.sshCommand=",
      "core.askPass=",
      "core.attributesFile=/dev/null",
      "core.useReplaceRefs=false",
      "core.excludesFile=/dev/null",
      "diff.external=",
      "interactive.diffFilter=",
      "protocol.allow=never",
      "protocol.ext.allow=never",
      "protocol.file.allow=never",
      "protocol.git.allow=always",
      "protocol.https.allow=always",
      "protocol.ssh.allow=always",
      "credential.helper="
    ].freeze
    ENV_ALLOWLIST = %w[
      CURL_CA_BUNDLE GH_CONFIG_DIR GH_ENTERPRISE_TOKEN GH_HOST GH_TOKEN
      GITHUB_TOKEN HOME HTTPS_PROXY HTTP_PROXY LANG LC_ALL NO_PROXY PATH
      SSH_AUTH_SOCK SSL_CERT_DIR SSL_CERT_FILE TMPDIR
    ].freeze
    EXECUTABLE_CONFIG = [
      /\Afilter\..*\.(?:clean|smudge|process)\z/,
      /\Aurl\..*\.(?:insteadof|pushinsteadof)\z/,
      /\Acredential(?:\..*)?\.helper\z/,
      /\Aremote\..*\.(?:uploadpack|receivepack)\z/,
      /\Auploadpack\.packobjectshook\z/,
      /\Acore\.(?:alternaterefscommand|gitproxy|pager)\z/,
      /\Ahttp(?:\..*)?\..+\z/,
      /\Apager\..*\z/
    ].freeze

    module_function

    # Return the checked-out submodule paths from a bounded, fixed Git read.
    # This deliberately does not expose a general ls-files/config surface.
    def tracked_gitlinks(path, max_stdout_bytes: DEFAULT_GITLINK_OUTPUT_BYTES)
      limit = Integer(max_stdout_bytes)
      raise ArgumentError, "managed Git gitlink output limit must be positive" unless limit.positive?

      out, _err, status, overflow = capture3_bounded_fixed(
        fixed_command(path, "ls-files", "--stage", "-z"), limit
      )
      unless status.success? && !overflow
        raise ArgumentError, "managed Git gitlink discovery failed"
      end

      paths = out.split("\0").filter_map do |record|
        next unless record.start_with?("160000 ")

        match = /\A160000 [0-9a-f]{40}(?:[0-9a-f]{24})? [0-3]\t(.+)\z/.match(record)
        raise ArgumentError, "managed Git gitlink discovery returned malformed index data" unless match

        gitlink_path!(match[1])
      end
      raise ArgumentError, "managed Git gitlink discovery exceeded the path limit" if
        paths.length > MAX_TRACKED_GITLINKS

      paths.uniq.sort.freeze
    rescue TypeError
      raise ArgumentError, "managed Git gitlink output limit must be positive"
    end

    # Set only the two private-repository values needed for ordinary Git
    # discovery through a .git directory or gitdir pointer. This is not a
    # generic config API: callers cannot choose the key, command, or value.
    def configure_isolated_worktree(git_dir:, worktree:)
      private_dir = existing_directory!(git_dir, "private Git directory")
      tree = existing_directory!(worktree, "private Git worktree")
      [ [ "core.bare", "false" ], [ "core.worktree", tree ] ].each do |key, value|
        out, err, status = capture3_isolated_config(private_dir, tree, key, value)
        next if status.success?

        detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
        raise ArgumentError, "managed Git private worktree configuration failed: #{detail[0, 200]}"
      end
      true
    end

    def capture3(path, *args, allow_local_transport: false, timeout_sec: nil,
                 env: ENV, **options)
      argv = command(
        path, *args, allow_local_transport: allow_local_transport, env: env
      )
      child_env = environment(env: env)
      return Open3.capture3(
        child_env, *argv, **options, unsetenv_others: true
      ) unless timeout_sec

      capture3_with_deadline(
        child_env, argv, timeout_sec: timeout_sec, **options
      )
    end

    def capture3_isolated(git_dir, worktree, *args, env: ENV, **options)
      command_name = args.first.to_s
      unless COMMANDS.include?(command_name)
        raise ArgumentError, "managed Git command is not allowed: #{command_name}"
      end

      argv = [
        "git", "--git-dir=#{File.expand_path(git_dir)}",
        "--work-tree=#{File.expand_path(worktree)}",
        *git_config(env).flat_map { |entry| [ "-c", entry ] },
        *harden_diff_args(args)
      ]
      Open3.capture3(
        environment(env: env), *argv, **options, unsetenv_others: true
      )
    end

    def popen3(path, *args, allow_local_transport: false, env: ENV,
               **options, &block)
      Open3.popen3(
        environment(env: env),
        *command(path, *args, allow_local_transport: allow_local_transport, env: env),
        **options, unsetenv_others: true, &block
      )
    end

    def command(path, *args, allow_local_transport: false, env: ENV)
      command_name = args.first.to_s
      raise ArgumentError, "managed Git command is not allowed: #{command_name}" unless COMMANDS.include?(command_name)

      hardened_args = harden_diff_args(args)
      config = git_config(env)
      if allow_local_transport
        config = config.reject { |entry| entry.start_with?("protocol.file.allow=") } +
                 [ "protocol.file.allow=always" ]
      end
      [ "git", "-C", File.expand_path(path), *config.flat_map { |entry| [ "-c", entry ] }, *hardened_args ]
    end

    def capture3_bounded(path, *args, max_stdout_bytes:,
                         allow_local_transport: false)
      capture3_bounded_fixed(
        command(path, *args, allow_local_transport: allow_local_transport),
        max_stdout_bytes
      )
    end

    def capture3_bounded_fixed(argv, max_stdout_bytes)
      out = String.new(capacity: [ max_stdout_bytes, 16 * 1024 ].min, encoding: Encoding::BINARY)
      err = String.new(capacity: 16 * 1024, encoding: Encoding::BINARY)
      overflow = false
      status = nil
      Open3.popen3(environment, *argv, pgroup: true, unsetenv_others: true) do |stdin, stdout, stderr, wait|
        stdin.close
        stdout.binmode
        stderr.binmode
        streams = {
          stdout => [ out, max_stdout_bytes ],
          stderr => [ err, 16 * 1024 ]
        }
        until streams.empty?
          readable = IO.select(streams.keys)&.first || []
          readable.each do |stream|
            chunk = stream.read_nonblock(16 * 1024, exception: false)
            if chunk.nil?
              streams.delete(stream)
              next
            end
            next if chunk == :wait_readable

            target, limit = streams.fetch(stream)
            available = limit - target.bytesize
            target << chunk.byteslice(0, available) if available.positive?
            next unless stream.equal?(stdout) && chunk.bytesize > available && !overflow

            overflow = true
            Process.kill("KILL", -wait.pid)
          rescue Errno::ESRCH
            nil
          end
        end
        status = wait.value
      ensure
        stdout.close unless stdout.closed?
        stderr.close unless stderr.closed?
      end
      [ out, err, status, overflow ]
    end
    private_class_method :capture3_bounded_fixed

    # Read only repository-local config key names through a fixed command.
    # The public facade uses this before every operation to refuse executable
    # helpers that cannot be neutralized generically (notably arbitrary
    # filter driver names from .gitattributes).
    def executable_local_config(path, env: ENV)
      out, err, status = Open3.capture3(
        environment(env: env),
        "git", "-C", File.expand_path(path),
        *git_config(env).flat_map { |entry| [ "-c", entry ] },
        "config", "--local", "--includes", "--name-only", "--null", "--list",
        unsetenv_others: true
      )
      return [ [], err, status ] unless status.success?

      names = out.split("\0").map(&:downcase)
      [ names.select { |name| EXECUTABLE_CONFIG.any? { |pattern| name.match?(pattern) } },
        err, status ]
    end

    def environment(env: ENV)
      ENV_ALLOWLIST.each_with_object({}) do |name, child_env|
        value = env[name]
        child_env[name] = value unless value.to_s.empty?
      end.merge(
        "GIT_ATTR_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL" => File::NULL,
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_SYSTEM" => File::NULL,
        "GIT_OPTIONAL_LOCKS" => "0",
        "GIT_NO_REPLACE_OBJECTS" => "1",
        "GIT_PROTOCOL_FROM_USER" => "0",
        "GIT_TERMINAL_PROMPT" => "0"
      )
    end

    def harden_diff_args(args)
      return args unless %w[diff show].include?(args.first.to_s)

      command_name, *rest = args
      [ command_name, "--no-ext-diff", "--no-textconv", *rest ]
    end
    private_class_method :harden_diff_args

    def capture3_isolated_config(git_dir, worktree, key, value)
      argv = [
        "git", "--git-dir=#{git_dir}", "--work-tree=#{worktree}",
        *git_config(ENV).flat_map { |entry| [ "-c", entry ] },
        "config", "--local", key, value
      ]
      Open3.capture3(environment, *argv, unsetenv_others: true)
    end
    private_class_method :capture3_isolated_config

    def fixed_command(path, *args)
      [
        "git", "-C", File.expand_path(path),
        *git_config(ENV).flat_map { |entry| [ "-c", entry ] }, *args
      ]
    end
    private_class_method :fixed_command

    def existing_directory!(path, label)
      expanded = File.expand_path(path.to_s)
      unless File.directory?(expanded)
        raise ArgumentError, "managed Git #{label} is unavailable"
      end

      File.realpath(expanded)
    rescue SystemCallError
      raise ArgumentError, "managed Git #{label} is unavailable"
    end
    private_class_method :existing_directory!

    def gitlink_path!(path)
      value = path.to_s
      unless !value.empty? && !value.start_with?("/") &&
             value.split(File::SEPARATOR).none? { |part| part.empty? || part == "." || part == ".." }
        raise ArgumentError, "managed Git gitlink path is invalid"
      end

      value
    end
    private_class_method :gitlink_path!

    def credential_helper_config(env)
      configured = env[GH_BIN_ENV].to_s.strip
      command = if configured.empty?
        "gh"
      else
        path = File.expand_path(configured)
        unless configured == path && File.file?(path) && File.executable?(path)
          raise ArgumentError, "#{GH_BIN_ENV} must name an absolute executable file"
        end
        Shellwords.escape(path)
      end
      "credential.https://github.com.helper=!#{command} auth git-credential"
    end
    private_class_method :credential_helper_config

    def git_config(env)
      CONFIG + [ credential_helper_config(env) ]
    end
    private_class_method :git_config

    def capture3_with_deadline(child_env, argv, timeout_sec:, **options)
      timeout = Float(timeout_sec)
      unless timeout.finite? && timeout.positive?
        raise ArgumentError, "managed Git timeout must be positive"
      end

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      stdout_data = ""
      stderr_data = ""
      status = nil
      timed_out = false
      spawn_options = options.merge(pgroup: true, unsetenv_others: true)
      Open3.popen3(child_env, *argv, **spawn_options) do |stdin, stdout, stderr, wait|
        stdin.close
        stdout.binmode
        stderr.binmode
        out_reader = Thread.new { read_stream(stdout) }
        err_reader = Thread.new { read_stream(stderr) }
        if [ wait, out_reader, err_reader ].all? { |thread| join_until(thread, deadline) }
          status = wait.value
          stdout_data = out_reader.value
          stderr_data = err_reader.value
        else
          timed_out = true
          terminate_process_group(wait.pid)
          stdout.close unless stdout.closed?
          stderr.close unless stderr.closed?
          status = wait.value
          stdout_data = thread_value(out_reader)
          stderr_data = thread_value(err_reader)
        end
      ensure
        stdout.close unless stdout.closed?
        stderr.close unless stderr.closed?
      end

      if timed_out
        detail = "managed Git command timed out after #{timeout_sec}s"
        stderr_data = stderr_data.dup
        stderr_data << "\n" unless stderr_data.empty? || stderr_data.end_with?("\n")
        stderr_data << detail
      end
      [ stdout_data, stderr_data, status ]
    end
    private_class_method :capture3_with_deadline

    def read_stream(stream)
      stream.read
    rescue IOError
      ""
    end
    private_class_method :read_stream

    def join_until(thread, deadline)
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      remaining.positive? && thread.join(remaining)
    end
    private_class_method :join_until

    def thread_value(thread)
      thread.join(TERMINATION_GRACE_SEC)
      thread.kill if thread.alive?
      thread.value.to_s
    rescue StandardError
      ""
    end
    private_class_method :thread_value

    def terminate_process_group(pid)
      Process.kill("TERM", -pid)
      sleep(TERMINATION_GRACE_SEC)
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH
      nil
    end
    private_class_method :terminate_process_group
  end
end
