require "open3"

module Hive
  # Hardened Git process boundary for controller work performed after a
  # managed agent has edited a repository. Repository data and local Git
  # configuration remain untrusted; fixed command-line overrides prevent
  # hooks, fsmonitor, external diff/textconv, custom transports, and arbitrary
  # credential/SSH helpers from executing in the controller process.
  module ManagedGit
    COMMANDS = %w[
      cat-file diff ls-remote merge-base push remote rev-list rev-parse show
      status symbolic-ref worktree
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

    module_function

    def capture3(path, *args, **options)
      Open3.capture3(environment, *command(path, *args), **options, unsetenv_others: true)
    end

    def popen3(path, *args, **options, &block)
      Open3.popen3(environment, *command(path, *args), **options, unsetenv_others: true, &block)
    end

    def command(path, *args)
      command_name = args.first.to_s
      raise ArgumentError, "managed Git command is not allowed: #{command_name}" unless COMMANDS.include?(command_name)

      hardened_args = harden_diff_args(args)
      [ "git", "-C", File.expand_path(path), *CONFIG.flat_map { |entry| [ "-c", entry ] }, *hardened_args ]
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
