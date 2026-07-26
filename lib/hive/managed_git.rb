require "open3"

module Hive
  # Hardened Git process boundary for controller work performed after a
  # managed agent has edited a repository. Repository data and local Git
  # configuration remain untrusted; fixed command-line overrides prevent
  # hooks, fsmonitor, external diff/textconv, custom transports, and arbitrary
  # credential/SSH helpers from executing in the controller process.
  module ManagedGit
    COMMANDS = %w[
      cat-file diff fetch ls-remote merge-base push remote rev-list rev-parse
      show status symbolic-ref worktree
    ].freeze
    CONFIG = [
      "core.hooksPath=/dev/null",
      "core.fsmonitor=false",
      "core.sshCommand=",
      "core.askPass=",
      "core.attributesFile=/dev/null",
      "core.excludesFile=/dev/null",
      "diff.external=",
      "interactive.diffFilter=",
      "protocol.allow=never",
      "protocol.ext.allow=never",
      "protocol.file.allow=never",
      "protocol.git.allow=always",
      "protocol.https.allow=always",
      "protocol.ssh.allow=always",
      "credential.helper=",
      "credential.https://github.com.helper=!gh auth git-credential"
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
      /\Acore\.(?:gitproxy|pager)\z/,
      /\Apager\..*\z/
    ].freeze

    module_function

    def capture3(path, *args, allow_local_transport: false, **options)
      Open3.capture3(
        environment, *command(path, *args, allow_local_transport: allow_local_transport),
        **options, unsetenv_others: true
      )
    end

    def popen3(path, *args, allow_local_transport: false, **options, &block)
      Open3.popen3(
        environment, *command(path, *args, allow_local_transport: allow_local_transport),
        **options, unsetenv_others: true, &block
      )
    end

    def command(path, *args, allow_local_transport: false)
      command_name = args.first.to_s
      raise ArgumentError, "managed Git command is not allowed: #{command_name}" unless COMMANDS.include?(command_name)

      hardened_args = harden_diff_args(args)
      config = CONFIG
      if allow_local_transport
        config = config.reject { |entry| entry.start_with?("protocol.file.allow=") } +
                 [ "protocol.file.allow=always" ]
      end
      [ "git", "-C", File.expand_path(path), *config.flat_map { |entry| [ "-c", entry ] }, *hardened_args ]
    end

    def capture3_bounded(path, *args, max_stdout_bytes:,
                         allow_local_transport: false)
      out = String.new(capacity: [ max_stdout_bytes, 16 * 1024 ].min, encoding: Encoding::BINARY)
      err = String.new(capacity: 16 * 1024, encoding: Encoding::BINARY)
      overflow = false
      status = nil
      popen3(
        path, *args, allow_local_transport: allow_local_transport,
        pgroup: true
      ) do |stdin, stdout, stderr, wait|
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

    # Read only repository-local config key names through a fixed command.
    # The public facade uses this before every operation to refuse executable
    # helpers that cannot be neutralized generically (notably arbitrary
    # filter driver names from .gitattributes).
    def executable_local_config(path)
      out, err, status = Open3.capture3(
        environment,
        "git", "-C", File.expand_path(path),
        *CONFIG.flat_map { |entry| [ "-c", entry ] },
        "config", "--local", "--name-only", "--null", "--list",
        unsetenv_others: true
      )
      return [ [], err, status ] unless status.success?

      names = out.split("\0").map(&:downcase)
      [ names.select { |name| EXECUTABLE_CONFIG.any? { |pattern| name.match?(pattern) } },
        err, status ]
    end

    def environment
      ENV_ALLOWLIST.each_with_object({}) do |name, env|
        value = ENV[name]
        env[name] = value unless value.to_s.empty?
      end.merge(
        "GIT_ATTR_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL" => File::NULL,
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_SYSTEM" => File::NULL,
        "GIT_OPTIONAL_LOCKS" => "0",
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
  end
end
