require "test_helper"
require_relative "../../packaging/betterleaks"
require_relative "../../packaging/release_candidate/artifacts"

class BetterleaksPackageTest < Minitest::Test
  include HiveTestHelper

  SECRET = "synthetic-private-credential"
  BODY = "verified fixture archive"
  DIGEST = Digest::SHA256.hexdigest(BODY)

  def test_tokens_use_precedence_private_files_and_origin_bound_redirects
    [ [ SECRET, "other", SECRET ], [ " \t#{SECRET} \t", "other", SECRET ],
      [ "", " \t#{SECRET} \t", SECRET ], [ " ", nil, nil ], [ nil, nil, nil ] ].each do |github, gh, expected|
      with_download(env: { "GITHUB_TOKEN" => github, "GH_TOKEN" => gh }) do |download, requests, _time|
        @responses = [ { headers: release_headers }, { headers: assets_headers } ]
        download.call
        assert_equal 2, requests.size
        if expected
          assert_equal "Authorization: Bearer #{expected}\n", requests[0][:authorization]
        else
          assert_nil requests[0][:authorization]
        end
        assert_nil requests[1][:authorization]
        requests.each do |request|
          args = request[:argv]
          assert_equal "--disable", args[1]
          assert_includes args, "=https"
          refute_includes args, "--location"
          refute_includes args, "--insecure"
          assert_equal "0", args[args.index("--retry") + 1]
          refute_includes args.join(" "), SECRET
          assert_operator request[:max_time], :<=, 300
          assert_operator request[:connect_time], :<=, 15
        end
      end
    end
  end

  def test_same_origin_and_relative_redirects_keep_auth_but_alternate_port_does_not
    with_download(env: { "GITHUB_TOKEN" => SECRET }) do |download, requests|
      @responses = [
        { status: 302, location: "/relative" },
        { status: 307, location: "https://github.com:443/explicit-port" },
        { status: 308, location: "https://github.com:444/alternate-port" },
        {}
      ]
      download.call
      assert_equal [ true, true, true, false ], requests.map { |request| !request[:authorization].nil? }
      assert_equal "https://github.com/relative", requests[1][:argv].last
    end
  end

  def test_auth_rejection_switches_once_to_anonymous_from_the_original_url
    [ 401, 403 ].each do |status|
      with_download(env: { "GITHUB_TOKEN" => SECRET }) do |download, requests|
        @responses = [ { status: 302, location: "/same-origin" }, { status: status }, {} ]
        _out, err = capture_io { download.call }
        assert_includes err, "retrying anonymously"
        assert_equal [ true, true, false ], requests.map { |request| !request[:authorization].nil? }
        assert_equal requests[0][:argv].last, requests[2][:argv].last
        refute_includes err, SECRET
      end
    end
  end

  def test_repeated_rejection_and_cdn_403_are_permanent
    [ [ { status: 401 }, { status: 403 } ],
      [ { headers: release_headers }, { status: 403 } ] ].each do |responses|
      with_download(env: { "GITHUB_TOKEN" => SECRET }) do |download, requests|
        @responses = responses.dup
        _out, err = capture_io do
          error = assert_raises(RuntimeError) { download.call }
          assert_includes error.message, "HTTP 403"
          refute_includes error.full_message, SECRET
        end
        assert_equal 2, requests.size
        refute_includes err, SECRET
      end
    end
  end

  def test_transient_http_transport_and_checksum_failures_retry_with_backoff
    [ { status: 408 }, { status: 429 }, { status: 503 }, { code: 7 }, { body: "bad digest" } ].each do |failure|
      with_download(env: { "GITHUB_TOKEN" => SECRET }) do |download, requests, time|
        @responses = [ failure, {} ]
        download.call
        assert_equal 2, requests.size
        assert_equal [ 5 ], time[:sleeps]
        assert_equal 5, time[:now]
        assert_operator requests.last[:max_time], :<=, 295
        assert requests.last[:authorization]
      end
    end
  end

  def test_persistent_failures_stop_at_one_deadline_including_backoff
    { "HTTP 503" => { status: 503 }, "checksum mismatch" => { body: "bad digest" },
      "transport code 28" => { code: 28 } }.each do |cause, failure|
      with_download do |download, requests, time|
        @responses = Array.new(20, failure)
        error = assert_raises(RuntimeError) { download.call }
        assert_includes error.message, "deadline exhausted"
        assert_includes error.message, "(#{HiveBetterleaksPackage::DOWNLOAD_BUDGET}s budget; last failure: #{cause})"
        assert_equal 300, time[:now]
        assert_equal [ 5, 10, 20, 30 ], time[:sleeps].first(4)
        assert_operator time[:sleeps].max, :<=, 30
        assert_operator requests.last[:started], :<, 300
      end
    end
  end

  def test_post_transfer_verification_can_finish_after_the_download_deadline
    [ true, false ].each do |valid|
      with_download do |download, requests, time|
        @responses = [ { elapsed: 299.9 } ]
        verification = ->(*) { time[:now] += 0.2; valid }
        with_replaced_singleton_method(HiveBetterleaksPackage, :verified?, verification) do
          if valid
            download.call
          else
            error = assert_raises(HiveBetterleaksPackage::DownloadError) { download.call }
            assert_includes error.message, "last failure: checksum mismatch"
          end
        end
        assert_equal 1, requests.size
        assert_empty time[:sleeps]
      end
    end
  end

  def test_missing_or_unusable_curl_stops_without_backoff
    [ -1, 1, 2, 3, 23 ].each do |code|
      with_download do |download, requests, time|
        @responses = [ { code: code } ]
        error = assert_raises(HiveBetterleaksPackage::DownloadError) { download.call }
        assert_equal "Betterleaks download invocation failure for linux_x64 (curl exit #{code})", error.message
        assert_equal 1, requests.size
        assert_empty time[:sleeps]
      end
    end
  end

  def test_slow_redirects_transfers_and_auth_fallback_share_the_original_deadline
    [ [ { status: 302, location: "/hop", elapsed: 299 }, { elapsed: 1 } ],
      [ { status: 401, elapsed: 300 } ],
      [ { status: 401, elapsed: 299 }, { status: 503, elapsed: 1 } ],
      [ { status: 503, elapsed: 298 } ] ].each do |responses|
      with_download(env: { "GITHUB_TOKEN" => SECRET }) do |download, requests, time|
        @responses = responses.dup
        capture_io do
          error = assert_raises(RuntimeError) { download.call }
          assert_includes error.message, "deadline exhausted"
        end
        assert_equal 300, time[:now]
        assert_operator requests.size, :<=, responses.size
        requests.each { |request| assert_operator request[:max_time], :<=, 300 - request[:started] }
        assert_operator time[:sleeps].sum, :<=, 2
      end
    end
  end

  def test_redirect_policy_and_malformed_response_fail_closed_without_sensitive_output
    [ "http://github.com/downgrade?#{SECRET}", "https://user:#{SECRET}@github.com/file", "https://[invalid" ].each do |location|
      with_download do |download, requests|
        @responses = [ { status: 302, location: location } ]
        error = assert_raises(RuntimeError) { download.call }
        refute_includes error.full_message, SECRET
        assert_equal 1, requests.size
      end
    end
    [ "HTTP/2 302\r\nLocation: /a\r\nLocation: /b\r\n\r\n",
      "HTTP/2 302\r\nX-Secret: #{SECRET}\r\n\r\n",
      "HTTP/2 200\r\nmalformed #{SECRET}\r\n\r\n",
      "HTTP/2 200\r\n\r\nHTTP/2 200\r\n\r\n" ].each do |headers|
      with_download do |download|
        @responses = [ { headers: headers } ]
        error = assert_raises(RuntimeError) { download.call }
        refute_includes error.full_message, SECRET
      end
    end
  end

  def test_redirect_loops_and_tls_failures_stop_without_backoff
    with_download do |download, requests, time|
      @responses = Array.new(11, { status: 302, location: "/loop" })
      error = assert_raises(RuntimeError) { download.call }
      assert_includes error.message, "redirect"
      assert_equal 11, requests.size
      assert_empty time[:sleeps]
    end
    [ 35, 60, 77, 90 ].each do |code|
      with_download do |download, requests, time|
        @responses = [ { code: code } ]
        error = assert_raises(RuntimeError) { download.call }
        assert_includes error.message, "TLS"
        assert_equal 1, requests.size
        assert_empty time[:sleeps]
      end
    end
  end

  def test_proxy_and_interim_header_blocks_are_parsed_before_the_final_response
    with_download do |download, requests|
      @responses = [ { headers: "HTTP/1.1 200 Connection established\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: </example>\r\n\r\n" + release_headers },
                     { headers: "HTTP/1.1 100 Continue\r\n\r\n" + assets_headers } ]
      download.call
      assert_equal 2, requests.size
    end
  end

  def test_malformed_token_is_redacted_and_never_sent
    [ "#{SECRET}\r\nInjected: value", "#{SECRET}\n", "\r#{SECRET}" ].each do |token|
      with_download(env: { "GITHUB_TOKEN" => token }) do |download, requests|
        error = assert_raises(RuntimeError) { download.call }
        assert_includes error.message, "token"
        refute_includes error.full_message, SECRET
        assert_empty requests
      end
    end
  end

  def test_subprocess_wrapper_enforces_remaining_time_and_reaps_the_child
    Dir.mktmpdir do |dir|
      pid_path = File.join(dir, "pid")
      before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      code = HiveBetterleaksPackage.run_curl(
        [ "sh", "-c", 'echo $$ > "$0"; exec sleep 30', pid_path ],
        deadline: before + 0.25
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - before
      assert_equal 28, code
      assert_operator elapsed, :<, 1.5
      pid = Integer(File.read(pid_path))
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
      assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
    end
  end

  def test_subprocess_errors_do_not_expose_the_underlying_exception
    with_replaced_singleton_method(Process, :spawn, ->(*) { raise Errno::ENOENT, SECRET }) do
      assert_equal(-1, HiveBetterleaksPackage.run_curl([ "curl" ], deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1))
    end
  end

  def test_every_packaging_diagnostic_passes_the_candidate_allowlist_without_raw_details
    messages = []
    capture_error = lambda do |&operation|
      messages << assert_raises(HiveBetterleaksPackage::DownloadError, &operation).message
    end
    # Exercise emitted messages rather than reproducing the forwarder's vocabulary.
    with_download do |download|
      [ { code: 60 }, { code: -1 }, { code: 2 }, { status: 404 },
        { status: 302, location: "http://example.com/#{SECRET}" },
        { headers: "malformed #{SECRET}" } ].each do |response|
        @responses = [ response ]
        capture_error.call { download.call }
      end
      [ { status: 503 }, { body: "bad digest" }, { code: 28 } ].each do |response|
        with_download do |retrying|
          @responses = Array.new(20, response)
          capture_error.call { retrying.call }
        end
      end
      with_replaced_singleton_method(File, :binread, ->(*) { raise IOError, SECRET }) do
        @responses = [ {} ]
        capture_error.call { download.call }
      end
      capture_error.call { HiveBetterleaksPackage.remaining!(0, "linux_x64") }
      capture_error.call { HiveBetterleaksPackage.curl_hop("https://github.com", "/unused", nil, 0.0000001, "linux_x64") }
    end
    with_download(env: { "GITHUB_TOKEN" => "#{SECRET}\n" }) do |download|
      capture_error.call { download.call }
    end
    with_download(env: { "GITHUB_TOKEN" => SECRET }) do |download|
      @responses = [ { status: 401 }, {} ]
      _out, warning = capture_io { download.call }
      messages.concat(warning.lines.map(&:chomp))
    end
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      archive = File.join(dir, "archive")
      FileUtils.mkdir_p(cache)
      File.write(File.join(cache, "#{DIGEST}.tar.gz"), "bad digest")
      _out, warning = capture_io { HiveBetterleaksPackage.cached_archive(cache, archive, DIGEST, "linux_x64") }
      messages.concat(warning.lines.map(&:chomp))
      with_replaced_singleton_method(FileUtils, :cp, ->(*) { raise Errno::EACCES, SECRET }) do
        _out, warning = capture_io do
          HiveBetterleaksPackage.cached_archive(cache, archive, DIGEST, "linux_x64")
          HiveBetterleaksPackage.publish_archive(cache, archive, DIGEST, "linux_x64")
        end
        messages.concat(warning.lines.map(&:chomp))
      end
      with_replaced_singleton_method(HiveBetterleaksPackage, :cached_archive, ->(*) { true }) do
        # A verified archive can still lack the required tar members.
        status = Struct.new(:success?).new(false)
        with_replaced_singleton_method(Open3, :capture3, ->(*) { [ "", SECRET, status ] }) do
          capture_error.call { HiveBetterleaksPackage.build(root: dir, cache_dir: cache) }
        end
      end
    end
    forwarder = HiveReleaseCandidate::Artifacts.allocate
    messages.each do |message|
      refute_includes message, SECRET
      _out, forwarded = capture_io { forwarder.send(:forward_betterleaks_diagnostics, "#{message}\n") }
      assert_equal "#{message}\n", forwarded
      _out, rejected = capture_io do
        forwarder.send(:forward_betterleaks_diagnostics, "#{message} #{SECRET}\n#{SECRET} #{message}\n")
      end
      assert_empty rejected
    end
  end

  private

  def release_headers
    File.binread(File.expand_path("../fixtures/betterleaks/github-release.headers", __dir__))
  end

  def assets_headers
    File.binread(File.expand_path("../fixtures/betterleaks/github-assets.headers", __dir__))
  end

  def with_download(env: {})
    Dir.mktmpdir do |dir|
      archive = File.join(dir, "archive.tar.gz")
      requests = []
      time = { now: 0.0, sleeps: [] }
      @responses = [ {} ]
      test_case = self
      transport = lambda do |argv, deadline:|
        header_arg = argv.index("--header")
        auth_file = header_arg && argv[header_arg + 1].delete_prefix("@")
        if auth_file
          test_case.assert_equal 0o600, File.stat(auth_file).mode & 0o777
        end
        requests << { argv: argv, authorization: auth_file && File.read(auth_file),
                      started: time[:now], max_time: Float(argv[argv.index("--max-time") + 1]),
                      connect_time: Float(argv[argv.index("--connect-timeout") + 1]) }
        response = test_case.instance_variable_get(:@responses).shift || test_case.flunk("unexpected additional request")
        time[:now] += response.fetch(:elapsed, 0)
        body_path = argv[argv.index("--output") + 1]
        File.binwrite(body_path, response.fetch(:body, BODY))
        headers = response[:headers] || "HTTP/2 #{response.fetch(:status, 200)}\r\n" \
                  "#{response[:location] && "Location: #{response[:location]}\r\n"}\r\n"
        File.binwrite(argv[argv.index("--dump-header") + 1], headers)
        response.fetch(:code, 0)
      end
      with_env({ "GITHUB_TOKEN" => nil, "GH_TOKEN" => nil, "HIVE_BETTERLEAKS_CACHE_DIR" => nil }.merge(env)) do
        with_replaced_singleton_method(HiveBetterleaksPackage, :monotonic_now, -> { time[:now] }) do
          with_replaced_singleton_method(HiveBetterleaksPackage, :sleep, ->(seconds) { time[:sleeps] << seconds; time[:now] += seconds }) do
            with_replaced_singleton_method(HiveBetterleaksPackage, :run_curl, transport) do
              yield -> { HiveBetterleaksPackage.download_archive(archive, DIGEST, "linux_x64") }, requests, time
            end
          end
        end
      end
      refute File.exist?(File.join(dir, "authorization.headers"))
      assert_empty Dir.glob(File.join(dir, "*.headers"))
    end
  end
end
