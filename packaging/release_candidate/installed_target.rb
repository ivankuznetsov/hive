# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require_relative "paths"

module HiveReleaseCandidate
  class InstalledTarget
    ROLES = %w[baseline observer candidate].freeze
    SAFE_HOST_ENV = %w[LANG LC_ALL TZ].freeze

    attr_reader :role, :root, :state_root, :manifest

    def self.install_contract(role:, install_root:, gem_path:, skills_archive:, offline_cache:,
                              dependency_gems:)
      validate_role!(role)
      root = File.expand_path(install_root)
      gem = regular_input!(gem_path, "candidate gem")
      skills = regular_input!(skills_archive, "skills archive")
      cache = File.expand_path(offline_cache)
      cache_stat = File.lstat(cache)
      unless cache_stat.directory? && !cache_stat.symlink? && cache_stat.uid == Process.uid
        raise Error, "offline gem cache must be an owned directory"
      end
      unless dependency_gems.is_a?(Array) && !dependency_gems.empty?
        raise Error, "offline gem cache must provide the complete dependency closure"
      end
      unless dependency_gems.uniq == dependency_gems
        raise Error, "offline dependency closure contains duplicate gem paths"
      end
      dependencies = dependency_gems.map do |path|
        dependency = regular_input!(path, "dependency gem")
        unless dependency.start_with?("#{cache}/")
          raise Error, "dependency gem must stay beneath the offline cache"
        end
        dependency
      end
      install_flags = [
        "--install-dir", root, "--bindir", File.join(root, "rubygems-bin"),
        "--local", "--ignore-dependencies", "--no-document"
      ]
      {
        "schema" => "hive-release-candidate-install-contract",
        "schema_version" => SCHEMA_VERSION,
        "role" => role,
        "network" => false,
        "install_root" => root,
        "dependency_install_argv" => dependencies.map do |dependency|
          [ "gem", "install", dependency, *install_flags ]
        end,
        "gem_install_argv" => [ "gem", "install", gem, *install_flags ],
        "offline_cache" => cache,
        "skills" => {
          "archive" => skills,
          "sha256" => Digest::SHA256.file(skills).hexdigest,
          "import_root" => File.join(root, "skills"),
          "mode" => "verified_archive_projection"
        }
      }
    end

    def self.validate_role!(role)
      raise UsageError, "installed target role must be baseline, observer, or candidate" unless ROLES.include?(role.to_s)
    end

    def self.regular_input!(path, label)
      expanded = File.expand_path(path)
      stat = File.lstat(expanded)
      unless stat.file? && !stat.symlink? && stat.nlink == 1 && stat.uid == Process.uid
        raise Error, "#{label} must be an owned regular file"
      end
      expanded
    rescue Errno::ENOENT, Errno::EACCES
      raise Error, "#{label} must be an owned regular file"
    end

    def initialize(role:, root:, state_root:)
      self.class.validate_role!(role)
      @role = role.to_s
      @root = File.expand_path(root)
      @state_root = File.expand_path(state_root)
      validate_owned_directory!(@root, "installed target root")
      manifest_path = File.join(@root, "target.json")
      stat = File.lstat(manifest_path)
      unless stat.file? && !stat.symlink? && stat.nlink == 1 && stat.uid == Process.uid
        raise Error, "installed target manifest must be an owned regular file"
      end
      @manifest = JSON.parse(File.read(manifest_path))
      validate_manifest!
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError => e
      raise Error, "installed target is invalid: #{e.message}"
    end

    def executable
      relative = manifest.fetch("executable")
      path = File.expand_path(relative, root)
      prefix = "#{root}/"
      raise Error, "installed target executable escapes its root" unless path.start_with?(prefix)
      stat = File.lstat(path)
      unless stat.file? && !stat.symlink? && stat.nlink == 1 && stat.uid == Process.uid &&
             (stat.mode & 0o111).positive?
        raise Error, "installed target executable must be an owned executable regular file"
      end
      path
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Error, "installed target executable is invalid: #{e.message}"
    end

    def environment(host_env = ENV.to_h)
      preserved = host_env.slice(*SAFE_HOST_ENV)
      home = File.join(state_root, "home")
      preserved.merge(
        "HOME" => home,
        "HIVE_HOME" => File.join(state_root, "hive"),
        "XDG_CONFIG_HOME" => File.join(state_root, "xdg", "config"),
        "XDG_CACHE_HOME" => File.join(state_root, "xdg", "cache"),
        "XDG_DATA_HOME" => File.join(state_root, "xdg", "data"),
        "XDG_STATE_HOME" => File.join(state_root, "xdg", "state"),
        "GEM_HOME" => root,
        "GEM_PATH" => root,
        "PATH" => [ File.join(root, "bin"), File.join(root, "rubygems-bin"), "/usr/bin", "/bin" ].join(":"),
        "BUNDLE_DISABLE_SHARED_GEMS" => "true",
        "BUNDLE_FROZEN" => "true",
        "BUNDLE_LOCAL__HIVE_CLI" => root
      )
    end

    private

    def validate_owned_directory!(path, label)
      stat = File.lstat(path)
      raise Error, "#{label} cannot be a symlink" if stat.symlink?
      raise Error, "#{label} must be a directory" unless stat.directory?
      raise Error, "#{label} is not owned by the current user" unless stat.uid == Process.uid
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Error, "#{label} is invalid: #{e.message}"
    end

    def validate_manifest!
      required = %w[executable gem_sha256 role schema schema_version skills version]
      unless manifest.is_a?(Hash) && manifest.keys.sort == required.sort &&
             manifest["schema"] == "hive-release-candidate-installed-target" &&
             manifest["schema_version"] == SCHEMA_VERSION &&
             manifest["role"] == role &&
             /\A[0-9a-f]{64}\z/.match?(manifest["gem_sha256"].to_s) &&
             manifest["version"].is_a?(String) && !manifest["version"].empty?
        raise Error, "installed target manifest identity is invalid"
      end
      skills = manifest["skills"]
      unless skills.is_a?(Hash) && skills.keys.sort == %w[archive_sha256 import_root] &&
             /\A[0-9a-f]{64}\z/.match?(skills["archive_sha256"].to_s) &&
             safe_relative_path?(skills["import_root"])
        raise Error, "installed target skills identity is invalid"
      end
      executable
    end

    def safe_relative_path?(value)
      return false unless value.is_a?(String) && !value.empty?

      path = Pathname.new(value)
      !path.absolute? && path.cleanpath.to_s != ".." &&
        !path.cleanpath.to_s.start_with?("../") && !value.include?("\\")
    end
  end
end
