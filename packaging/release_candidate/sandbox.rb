# frozen_string_literal: true

require "open3"
require_relative "paths"

module HiveReleaseCandidate
  class Sandbox
    PINNED_IMAGE = /\A[a-z0-9][a-z0-9._\/-]*@sha256:[0-9a-f]{64}\z/.freeze

    def initialize(command_probe: nil)
      @command_probe = command_probe || method(:probe)
    end

    def capability(candidate_sha:)
      unless SAFE_SHA.match?(candidate_sha.to_s)
        raise UsageError, "candidate_sha must be a full 40-character commit SHA"
      end
      %w[podman docker].each do |engine|
        version = @command_probe.call(engine)
        next if version.to_s.empty?

        return {
          "status" => "available",
          "kind" => "container",
          "engine" => engine,
          "version" => version.to_s.strip,
          "network_after_staging" => "none"
        }
      end
      {
        "status" => "unavailable",
        "reason" => "compliant_local_sandbox_unavailable",
        "next_action_argv" => [
          "bin/hive-release-candidate", "dispatch", "--sha", candidate_sha.to_s
        ]
      }
    end

    def container_contract(engine:, image:, repo_root:, cache_root:, run_root:, command:)
      raise UsageError, "unsupported container engine #{engine.inspect}" unless %w[podman docker].include?(engine)
      raise Error, "sandbox image must be pinned by SHA-256 digest" unless PINNED_IMAGE.match?(image.to_s)
      raise UsageError, "sandbox command must be a non-empty argv array" unless argv?(command)
      repo = owned_directory!(repo_root, "repository")
      cache = owned_directory!(cache_root, "artifact cache")
      run = owned_directory!(run_root, "run root")
      argv = [
        engine, "run", "--rm", "--network=none", "--read-only",
        "--cap-drop=ALL", "--security-opt=no-new-privileges",
        "--pids-limit=256"
      ]
      if engine == "podman"
        argv << "--userns=keep-id"
      else
        argv << "--user=#{Process.uid}:#{Process.gid}"
      end
      argv.concat([
        "--tmpfs=/tmp:rw,nosuid,nodev,noexec,size=512m",
        "--volume", "#{repo}:/repo:ro",
        "--volume", "#{cache}:/cache:ro",
        "--volume", "#{run}:/run:rw",
        "--env", "HOME=/run/home",
        "--env", "HIVE_HOME=/run/hive",
        "--env", "XDG_CONFIG_HOME=/run/xdg/config",
        "--env", "XDG_CACHE_HOME=/run/xdg/cache",
        "--env", "XDG_DATA_HOME=/run/xdg/data",
        "--env", "XDG_STATE_HOME=/run/xdg/state",
        image,
        *command
      ])
    end

    private

    def probe(command)
      path = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map do |directory|
        candidate = File.join(directory, command)
        candidate if File.file?(candidate) && File.executable?(candidate)
      end.first
      return nil unless path

      stdout, _stderr, status = Open3.capture3(path, "--version")
      return nil unless status.success?
      _info_out, _info_err, info_status = Open3.capture3(path, "info")
      info_status.success? ? stdout.lines.first.to_s.strip : nil
    rescue SystemCallError
      nil
    end

    def owned_directory!(path, label)
      expanded = File.expand_path(path)
      stat = File.lstat(expanded)
      raise Error, "#{label} cannot be a symlink" if stat.symlink?
      raise Error, "#{label} must be an owned directory" unless stat.directory? && stat.uid == Process.uid
      expanded
    rescue Errno::ENOENT, Errno::EACCES
      raise Error, "#{label} must be an owned directory"
    end

    def argv?(value)
      value.is_a?(Array) && !value.empty? &&
        value.all? { |item| item.is_a?(String) && !item.empty? && !item.include?("\0") }
    end
  end
end
