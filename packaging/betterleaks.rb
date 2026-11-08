#!/usr/bin/env ruby
# Build-time only: bundle pinned, checksum-verified upstream binaries and
# their license. Runtime scans never download or update executable code.
require "digest"
require "fileutils"
require "open3"
require "tempfile"
require "tmpdir"
require "uri"
require_relative "../lib/hive/betterleaks"

module HiveBetterleaksPackage
  DOWNLOAD_BUDGET = 300
  REDIRECT_STATUSES = [ 301, 302, 303, 307, 308 ].freeze
  TLS_FAILURES = [ 35, 51, 53, 58, 59, 60, 64, 66, 77, 80, 82, 83, 90, 91, 98 ].freeze
  TRANSIENT_CURL_FAILURES = [ 5, 6, 7, 16, 18, 28, 52, 55, 56, 81, 89, 92, 95, 96 ].freeze

  class DownloadError < RuntimeError; end

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
        raise DownloadError, "Betterleaks extraction failed for #{platform}" unless status.success?

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
    original = "https://github.com/betterleaks/betterleaks/releases/download/v#{Hive::Betterleaks::VERSION}/" \
               "betterleaks_#{Hive::Betterleaks::VERSION}_#{platform}.tar.gz"
    token = [ ENV["GITHUB_TOKEN"], ENV["GH_TOKEN"] ].find { |value| !value.to_s.strip.empty? }
    if token&.match?(/[\r\n]/)
      raise DownloadError, "Betterleaks invalid authentication token for #{platform}"
    end
    token = token&.strip

    deadline = monotonic_now + DOWNLOAD_BUDGET
    authorization = File.join(File.dirname(archive), "authorization.headers")
    if token
      File.open(authorization, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write("Authorization: Bearer #{token}\n")
      end
    end
    authenticated = !token.nil?
    url = original
    redirects = 0
    delay = 5
    last_failure = nil
    loop do
      remaining!(deadline, platform, last_failure)
      FileUtils.rm_f(archive)
      credentialed = authenticated && release_origin?(url)
      response = curl_hop(url, archive, credentialed ? authorization : nil, deadline, platform, last_failure)
      code = response.fetch(:code)
      if TLS_FAILURES.include?(code)
        raise DownloadError, "Betterleaks download TLS failure for #{platform}"
      end
      unless code.zero? || TRANSIENT_CURL_FAILURES.include?(code)
        raise DownloadError, "Betterleaks download invocation failure for #{platform} (curl exit #{code})"
      end
      last_failure = code.zero? ? [ :http, response.fetch(:status) ] : [ :transport, code ]
      remaining!(deadline, platform, last_failure)
      if code.zero?
        status = response.fetch(:status)
        if credentialed && [ 401, 403 ].include?(status)
          authenticated = false
          FileUtils.rm_f(authorization)
          warn "Betterleaks authentication rejected for #{platform}; retrying anonymously"
          url = original
          redirects = 0
          next
        elsif REDIRECT_STATUSES.include?(status)
          redirects += 1
          if redirects > 10 || response[:location].to_s.empty?
            raise DownloadError, "Betterleaks download redirect policy failure for #{platform}"
          end
          url = redirect_url(url, response[:location], platform)
          next
        elsif (200..299).cover?(status)
          return if verified?(archive, digest)

          last_failure = [ :checksum ]
        elsif status != 408 && status != 429 && !(500..599).cover?(status)
          raise DownloadError, "Betterleaks download HTTP #{status} for #{platform}"
        end
      end
      sleep([ delay, remaining!(deadline, platform, last_failure) ].min)
      remaining!(deadline, platform, last_failure)
      delay = [ delay * 2, 30 ].min
      url = original
      redirects = 0
    end
  ensure
    FileUtils.rm_f(authorization) if authorization
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def remaining!(deadline, platform, last_failure = nil)
    remaining = deadline - monotonic_now
    if remaining <= 0
      raise DownloadError, deadline_message(platform, last_failure)
    end
    remaining
  end

  def deadline_message(platform, last_failure)
    cause = case last_failure&.first
    when :http then "HTTP #{last_failure[1]}"
    when :transport then "transport code #{last_failure[1]}"
    when :checksum then "checksum mismatch"
    else "none"
    end
    "Betterleaks download deadline exhausted for #{platform} (#{DOWNLOAD_BUDGET}s budget; last failure: #{cause})"
  end

  def release_origin?(url)
    uri = URI.parse(url)
    uri.scheme == "https" && uri.hostname&.downcase == "github.com" && uri.port == 443
  end

  def redirect_url(current, location, platform)
    uri = URI.join(current, location)
    unless uri.is_a?(URI::HTTPS) && uri.hostname && !uri.hostname.empty? && !uri.userinfo
      raise URI::InvalidURIError
    end
    uri.to_s
  rescue URI::Error, ArgumentError
    raise DownloadError, "Betterleaks download redirect policy failure for #{platform}", cause: nil
  end

  def curl_hop(url, archive, authorization, deadline, platform, last_failure = nil)
    # Round down: curl treats a zero timeout as unlimited.
    remaining = remaining!(deadline, platform, last_failure).floor(6)
    if remaining <= 0
      raise DownloadError, deadline_message(platform, last_failure)
    end
    headers = File.join(File.dirname(archive), "response.headers")
    argv = [ "curl", "--disable", "--silent", "--globoff",
             "--proto", "=https", "--proto-redir", "=https", "--retry", "0",
             "--connect-timeout", format("%.6f", [ 15, remaining ].min),
             "--max-time", format("%.6f", remaining),
             "--dump-header", headers, "--output", archive ]
    argv += [ "--header", "@#{authorization}" ] if authorization
    argv << url
    code = run_curl(argv, deadline: deadline)
    return { code: code } unless code.zero?

    parse_headers(File.binread(headers), platform).merge(code: code)
  rescue SystemCallError, IOError
    raise DownloadError, "Betterleaks download response unavailable for #{platform}", cause: nil
  ensure
    FileUtils.rm_f(headers) if headers
  end

  def parse_headers(raw, platform)
    failure = "Betterleaks download response policy failure for #{platform}"
    raise DownloadError, failure unless raw.end_with?("\r\n\r\n", "\n\n")

    blocks = raw.split(/\r?\n\r?\n/)
    response = nil
    blocks.each_with_index do |block, index|
      lines = block.split(/\r?\n/)
      match = lines.shift&.match(/\AHTTP\/(?:1\.[01]|2|3) ([1-5][0-9]{2})(?:[ \t]+[^\r\n]*)?\z/)
      raise DownloadError, failure unless match
      status = Integer(match[1])
      locations = []
      lines.each do |line|
        field = line.match(/\A([!#$%&'*+.^_`|~0-9A-Za-z-]+):[ \t]*([^\r\n]*)\z/)
        raise DownloadError, failure unless field
        locations << field[2].strip if field[1].downcase == "location"
      end
      raise DownloadError, failure if locations.size > 1
      if index < blocks.size - 1
        interim = status < 200 && status != 101
        proxy = block.lines.first.strip.match?(/\AHTTP\/1\.[01] 200 Connection established\z/i)
        raise DownloadError, failure unless interim || proxy
      else
        raise DownloadError, failure if status < 200
        response = { status: status, location: locations.first }
      end
    end
    response || raise(DownloadError, failure)
  end

  def run_curl(argv, deadline:)
    return 28 if monotonic_now >= deadline

    # Discard raw transport output. A process group and a parent-enforced
    # deadline also bound a stuck curl, independent of its own timeout flags.
    pid = Process.spawn(*argv, out: File::NULL, err: File::NULL, pgroup: true)
    waiter = Process.detach(pid)
    return 28 unless waiter.join([ deadline - monotonic_now, 0 ].max)

    waiter.value.exitstatus || -1
  rescue SystemCallError
    -1
  ensure
    if pid
      begin
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end
      waiter&.join
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    HiveBetterleaksPackage.build
  rescue HiveBetterleaksPackage::DownloadError => error
    warn error.message
    exit 1
  end
end
