# frozen_string_literal: true

require "fileutils"
require "open3"

module HiveManagedWebArchive
  class Error < StandardError; end

  module_function

  def build(repo_root:, candidate_sha:, version:, destination:)
    unless /\A[0-9a-f]{40}\z/.match?(candidate_sha.to_s)
      raise Error, "candidate SHA must be a full 40-character commit SHA"
    end
    unless /\A[0-9A-Za-z][0-9A-Za-z.-]*\z/.match?(version.to_s)
      raise Error, "version is not safe for an archive filename"
    end

    destination = File.expand_path(destination)
    FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
    raise Error, "refusing to overwrite managed web archive" if File.exist?(destination) || File.symlink?(destination)

    _stdout, stderr, status = Open3.capture3(
      "git", "archive", "--format=tar.gz", "--output", destination,
      "#{candidate_sha}:web", chdir: repo_root
    )
    unless status.success? && File.file?(destination) && !File.symlink?(destination)
      FileUtils.rm_f(destination)
      raise Error, "cannot build committed managed web archive: #{stderr.strip}"
    end
    destination
  end
end
