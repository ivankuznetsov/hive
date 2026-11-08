#!/usr/bin/env ruby
# Build-time only: bundle pinned, checksum-verified upstream binaries and
# their license. Runtime scans never download or update executable code.
require "digest"
require "fileutils"
require "open3"
require "tempfile"
require "tmpdir"
require_relative "../lib/hive/betterleaks"

module HiveBetterleaksPackage
  module_function

  def build(root: Hive::Betterleaks::ROOT, cache_dir: ENV["HIVE_BETTERLEAKS_CACHE_DIR"])
    cache_dir = nil if cache_dir.to_s.empty?
    Hive::Betterleaks::ASSETS.each do |platform, digest|
      Dir.mktmpdir("hive-betterleaks-package-") do |temporary|
        archive = File.join(temporary, "betterleaks.tar.gz")
        unless cached_archive(cache_dir, archive, digest, platform)
          download_archive(archive, digest, platform)
          publish_archive(cache_dir, archive, digest, platform) if cache_dir
        end
        _out, _err, status = Open3.capture3("tar", "-xzf", archive, "-C", temporary, "betterleaks", "LICENSE")
        raise "Betterleaks extraction failed for #{platform}" unless status.success?

        destination = File.join(root, platform)
        FileUtils.mkdir_p(destination)
        FileUtils.install(File.join(temporary, "betterleaks"), destination, mode: 0o755)
        FileUtils.install(File.join(temporary, "LICENSE"), destination, mode: 0o644)
      end
    end
  end

  def verified?(archive, digest)
    Digest::SHA256.file(archive).hexdigest == digest
  end

  def cached_archive(cache_dir, archive, digest, platform)
    return false unless cache_dir

    # Hash and extract the same private copy even when another publisher
    # replaces the shared entry after the copy has started.
    FileUtils.cp(File.join(cache_dir, "#{digest}.tar.gz"), archive)
    return true if verified?(archive, digest)

    warn "Betterleaks cache checksum mismatch for #{platform}; downloading"
    false
  rescue Errno::ENOENT
    false
  rescue SystemCallError, IOError => error
    cache_diagnostic("read", platform, error)
    false
  end

  def publish_archive(cache_dir, archive, digest, platform)
    FileUtils.mkdir_p(cache_dir)
    Tempfile.create([ ".betterleaks-", ".tar.gz" ], cache_dir) do |file|
      FileUtils.cp(archive, file.path)
      File.rename(file.path, File.join(cache_dir, "#{digest}.tar.gz"))
    end
  rescue SystemCallError, IOError => error
    cache_diagnostic("write", platform, error)
  end

  def cache_diagnostic(operation, platform, error)
    warn "Betterleaks cache #{operation} failed for #{platform} (#{error.class}); using verified temporary archive"
  end

  def download_archive(archive, digest, platform)
    url = "https://github.com/betterleaks/betterleaks/releases/download/v#{Hive::Betterleaks::VERSION}/" \
          "betterleaks_#{Hive::Betterleaks::VERSION}_#{platform}.tar.gz"
    _out, _err, status = Open3.capture3("curl", "--fail", "--location", "--silent", "--show-error",
                                     "--proto", "=https", "--proto-redir", "=https",
                                     "--retry", "3", "--retry-max-time", "60",
                                     "--connect-timeout", "15", "--max-time", "120",
                                     "--output", archive, url)
    raise "Betterleaks download failed for #{platform}" unless status.success?
    raise "Betterleaks checksum mismatch for #{platform}" unless verified?(archive, digest)
  end
end

HiveBetterleaksPackage.build if $PROGRAM_NAME == __FILE__
