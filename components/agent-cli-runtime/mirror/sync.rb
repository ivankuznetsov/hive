#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "find"
require "json"

module AgentCliRuntimeMirror
  SOURCE_REPOSITORY = "ivankuznetsov/hive"
  COMPONENT_PATH = "components/agent-cli-runtime"
  SOURCE_SHA = /\A[0-9a-f]{40}\z/
  ADMIN_FILES = {
    "sync.rb" => ".github/mirror/sync.rb",
    "sync-from-hive.yml" => ".github/workflows/sync-from-hive.yml",
    "mirror-release.yml" => ".github/workflows/mirror-release.yml",
    "CONTRIBUTING.md" => "CONTRIBUTING.md",
    "SECURITY.md" => "SECURITY.md"
  }.freeze

  module_function

  def run(arguments)
    source_arg, destination_arg, source_commit, mode, *extra = arguments
    usage! unless source_arg && destination_arg && source_commit && extra.empty?
    usage! unless mode.nil? || mode == "--release"
    abort "invalid source commit: #{source_commit.inspect}" unless source_commit.match?(SOURCE_SHA)

    source = verified_directory(source_arg, "source")
    destination = verified_directory(destination_arg, "destination")
    verify_distinct_roots!(source, destination)
    verify_git_checkout!(destination)
    reject_source_symlinks!(source)

    release = mode == "--release"
    admin_presence = ADMIN_FILES.keys.to_h do |path|
      [ path, File.file?(File.join(source, "mirror", path)) ]
    end
    reject_partial_admin!(admin_presence) unless release
    admin_available = admin_presence.values.all?
    preserve = [ ".git" ]
    preserve.concat([ ".github", "CONTRIBUTING.md", "SECURITY.md" ]) unless release || admin_available

    replace_payload(source, destination, preserve:)
    install_admin_files(source, destination) if !release && admin_available
    write_manifest(destination, source_commit)
  end

  def usage!
    abort "usage: sync.rb SOURCE_COMPONENT DESTINATION SOURCE_COMMIT [--release]"
  end

  def verified_directory(path, label)
    expanded = File.expand_path(path)
    abort "#{label} is not a directory: #{expanded}" unless File.directory?(expanded)

    File.realpath(expanded)
  end

  def verify_distinct_roots!(source, destination)
    separator = File::SEPARATOR
    nested = source == destination ||
             source.start_with?("#{destination}#{separator}") ||
             destination.start_with?("#{source}#{separator}")
    abort "source and destination must be separate trees" if nested
  end

  def verify_git_checkout!(destination)
    git = File.join(destination, ".git")
    state = File.lstat(git)
    abort "destination .git must be a real directory" unless state.directory? && !state.symlink?
  rescue Errno::ENOENT
    abort "destination is not a Git checkout: #{destination}"
  end

  def reject_partial_admin!(admin_presence)
    return if admin_presence.values.none? || admin_presence.values.all?

    missing = admin_presence.reject { |_path, present| present }.keys.sort
    abort "source mirror administration is incomplete: missing #{missing.join(", ")}"
  end

  def reject_source_symlinks!(source)
    Find.find(source) do |path|
      abort "source contains a symlink: #{path}" if File.lstat(path).symlink?
    end
  end

  def replace_payload(source, destination, preserve:)
    Dir.children(destination).each do |entry|
      next if preserve.include?(entry)

      FileUtils.rm_rf(File.join(destination, entry))
    end

    Dir.children(source).sort.each do |entry|
      next if entry == "mirror"

      FileUtils.cp_r(
        File.join(source, entry),
        destination,
        preserve: true
      )
    end
  end

  def install_admin_files(source, destination)
    ADMIN_FILES.each do |source_name, destination_path|
      target = File.join(destination, destination_path)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(
        File.join(source, "mirror", source_name),
        target,
        preserve: true
      )
    end
  end

  def write_manifest(destination, source_commit)
    payload = {
      repository: SOURCE_REPOSITORY,
      component_path: COMPONENT_PATH,
      source_commit: source_commit
    }
    File.write(
      File.join(destination, ".mirror-source.json"),
      "#{JSON.pretty_generate(payload)}\n"
    )
  end
end

AgentCliRuntimeMirror.run(ARGV)
