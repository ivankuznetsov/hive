#!/usr/bin/env ruby
# Build-time only: bundle pinned, checksum-verified upstream binaries and
# their license. Runtime scans never download or update executable code.
require "digest"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../lib/hive/betterleaks"

module HiveBetterleaksPackage
  module_function

  def build(root: Hive::Betterleaks::ROOT)
    Hive::Betterleaks::ASSETS.each do |platform, digest|
      destination = File.join(root, platform)
      FileUtils.mkdir_p(destination)
      Dir.mktmpdir("hive-betterleaks-package-") do |temporary|
        archive = File.join(temporary, "betterleaks.tar.gz")
        url = "https://github.com/betterleaks/betterleaks/releases/download/v#{Hive::Betterleaks::VERSION}/" \
              "betterleaks_#{Hive::Betterleaks::VERSION}_#{platform}.tar.gz"
        _out, _err, status = Open3.capture3("curl", "--fail", "--location", "--silent", "--show-error",
                                         "--proto", "=https", "--proto-redir", "=https", "--output", archive, url)
        raise "Betterleaks download failed for #{platform}" unless status.success?
        raise "Betterleaks checksum mismatch for #{platform}" unless Digest::SHA256.file(archive).hexdigest == digest

        _out, _err, status = Open3.capture3("tar", "-xzf", archive, "-C", temporary, "betterleaks", "LICENSE")
        raise "Betterleaks extraction failed for #{platform}" unless status.success?

        FileUtils.install(File.join(temporary, "betterleaks"), destination, mode: 0o755)
        FileUtils.install(File.join(temporary, "LICENSE"), destination, mode: 0o644)
      end
    end
  end
end

HiveBetterleaksPackage.build if $PROGRAM_NAME == __FILE__
