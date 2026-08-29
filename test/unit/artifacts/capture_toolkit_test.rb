require "test_helper"
require "hive/artifacts/capture_toolkit"
require "hive/agent_support/pi"
require "hive/commands/evidence"

class ArtifactsCaptureToolkitTest < Minitest::Test
  include HiveTestHelper

  FakeBrowser = Data.define(
    :cache_root, :agent_browser_cli, :browser_executable, :agent_browser_version,
    :browsers_path, :skills_path, :cache_key
  )

  def test_document_only_receipt_needs_no_external_capture_tools
    Dir.mktmpdir("hive-capture-toolkit-document") do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p(source)
      toolkit = Hive::Artifacts::CaptureToolkit.new(
        browser_bundle: -> { flunk "document proof must not bootstrap a browser" },
        tool_resolver: ->(_name) { flunk "document proof must not probe media tools" }
      )

      receipt = toolkit.prepare!(
        kinds: [ "document" ], task_root: root, source_root: source,
        source_sha: "a" * 40, writable_root: File.join(root, "work")
      )

      assert_equal [ "document" ], receipt.fetch("required_kinds")
      assert_nil receipt["web"]
      assert_nil receipt["terminal"]
    end
  end

  def test_pi_receipt_compiles_controller_scoped_producer_tools
    Dir.mktmpdir("hive-capture-toolkit-pi") do |root|
      source = File.join(root, "source")
      writable = File.join(root, "outcome-evidence", "work", "generation", "attempt")
      FileUtils.mkdir_p([ source, writable ])
      policy = Object.new
      policy.define_singleton_method(:cleanup!) { true }
      compiled = nil
      compile = lambda do |**kwargs|
        compiled = kwargs
        policy
      end
      toolkit = Hive::Artifacts::CaptureToolkit.new(hive_executable: "/opt/hive/bin/hive")

      receipt = with_replaced_singleton_method(
        Hive::AgentSupport::Pi::Runtime, :compile_evidence_actor, compile
      ) do
        toolkit.prepare!(
          kinds: %w[document terminal], task_root: root, source_root: source,
          source_sha: "a" * 40, writable_root: writable,
          producer_profile: Hive::AgentProfiles.lookup(:pi)
        )
      end

      assert_same policy, toolkit.producer_runtime_policy
      assert_equal File.realpath(source), compiled.fetch(:task_folder)
      assert_equal File.realpath(root), compiled.fetch(:package_root)
      assert_equal File.realpath(writable), compiled.fetch(:writable_root)
      assert_equal false, compiled.fetch(:browser)
      assert_equal "evidence_write", receipt.dig("producer_interface", "document")
      assert_equal "evidence_terminal", receipt.dig("producer_interface", "terminal")
      refute receipt.dig("producer_interface").key?("browser")
      toolkit.close
      assert_nil toolkit.producer_runtime_policy
    end
  end

  def test_managed_capture_rejects_an_unsupported_producer
    Dir.mktmpdir("hive-capture-toolkit-unsupported") do |root|
      source = File.join(root, "source")
      writable = File.join(root, "outcome-evidence", "work", "generation", "attempt")
      FileUtils.mkdir_p([ source, writable ])
      profile = Struct.new(:name).new(:unsupported)
      toolkit = Hive::Artifacts::CaptureToolkit.new

      error = assert_raises(Hive::ConfigError) do
        toolkit.prepare!(
          kinds: [ "terminal" ], task_root: root, source_root: source,
          source_sha: "a" * 40, writable_root: writable,
          producer_profile: profile
        )
      end

      assert_includes error.message, "does not support producer :unsupported"
      mailbox = toolkit.launch_environment.fetch("HIVE_EVIDENCE_CAPTURE_MAILBOX")
      refute File.exist?(mailbox)
    end
  end

  def test_visual_receipt_uses_only_managed_agent_browser_and_media_preflight
    Dir.mktmpdir("hive-capture-toolkit-generic") do |root|
    entry = FakeBrowser.new(
      cache_root: "/managed/capture-cache",
      agent_browser_cli: "/managed/agent-browser",
      browser_executable: "/managed/browsers/chrome",
      agent_browser_version: "0.34.0",
      browsers_path: "/managed/browsers", skills_path: "/managed/skills",
      cache_key: "b" * 64
    )
    bundle = Object.new
    bundle.define_singleton_method(:ensure!) { entry }
    tools = {
      "ffmpeg" => "/usr/bin/ffmpeg", "ffprobe" => "/usr/bin/ffprobe",
      "tesseract" => "/usr/bin/tesseract", "env" => "/usr/bin/env"
    }
    browser_commands = []
    toolkit = Hive::Artifacts::CaptureToolkit.new(
      browser_bundle: bundle, tool_resolver: ->(name) { tools[name] },
      hive_executable: "/opt/hive/bin/hive",
      runtime_resolver: method(:fake_codex_runtime),
      browser_command_runner: ->(environment, argv) { browser_commands << [ environment, argv ] }
    )

    receipt = toolkit.prepare!(
      kinds: %w[screenshot video], task_root: root, source_root: root,
      source_sha: "a" * 40, writable_root: File.join(root, "work")
    )

    assert_equal "agent-browser", receipt.dig("web", "driver")
    assert_equal "cli", receipt.dig("web", "interface")
    assert_equal "ready", receipt.dig("web", "status")
    assert_equal File.join(root, "work"), receipt.dig("web", "output_root")
    command = receipt.dig("web", "argv_prefix")
    assert_equal [ RbConfig.ruby, "/opt/hive/bin/hive", "evidence", "browser" ], command
    socket_root = browser_commands.first.first.fetch("AGENT_BROWSER_SOCKET_DIR")
    assert_operator socket_root.bytesize, :<, 70
    assert File.directory?(socket_root)
    mailbox_root = toolkit.launch_environment.fetch("HIVE_EVIDENCE_CAPTURE_MAILBOX")
    assert File.directory?(mailbox_root)
    assert File.pipe?(File.join(mailbox_root, "requests.fifo"))
    assert_equal [ mailbox_root ], toolkit.producer_add_dirs
    refute_equal socket_root, mailbox_root
    permission_arguments = toolkit.producer_permission_arguments
    assert_includes permission_arguments, 'default_permissions="hive-evidence"'
    assert_includes permission_arguments, "--enable"
    assert_includes permission_arguments, "network_proxy"
    assert permission_arguments.any? { |value| value.include?('network.mode="limited"') }
    assert permission_arguments.any? { |value| value.include?("allow_local_binding=true") }
    assert permission_arguments.any? { |value| value.include?("network.domains={}") }
    refute permission_arguments.any? { |value| value.include?("unix_sockets") }
    filesystem_policy = permission_arguments.find { |value| value.include?("filesystem=") }
    assert_includes filesystem_policy, mailbox_root
    assert_includes filesystem_policy, "/managed/capture-cache"
    assert_includes filesystem_policy, "/managed/codex-runtime"
    assert_includes filesystem_policy, "/opt/hive/bin/hive"
    assert_includes filesystem_policy, "/opt/hive/lib"
    domain = URI.parse(receipt.dig("web", "origin")).host
    browser_environment, browser_argv = browser_commands.first
    assert_includes browser_argv, domain
    assert_equal domain, browser_environment.fetch("AGENT_BROWSER_ALLOWED_DOMAINS")
    assert_match(%r{\Ahttp://127\.0\.0\.1:\d+\z}, browser_environment.fetch("AGENT_BROWSER_PROXY"))
    downloads = browser_environment.fetch("AGENT_BROWSER_DOWNLOAD_PATH")
    assert_match(%r{\A/tmp/hive-browser-state-}, downloads)
    refute downloads.start_with?(File.join(root, "work"))
    assert_match(%r{\Ahttp://127\.0\.0\.1:\d+\z}, receipt.dig("web", "app_endpoint"))
    refute_includes JSON.generate(receipt), "playwright"
    refute_includes JSON.generate(receipt), "firefox"
    assert_equal tools.except("env"), receipt.fetch("media")
    assert_equal File.join(root, "work"),
                 toolkit.launch_environment.fetch("HIVE_EVIDENCE_WRITE_ROOT")
    refute toolkit.launch_environment.key?("HOME")
    refute toolkit.launch_environment.key?("AGENT_BROWSER_EXECUTABLE_PATH")
    assert_equal %w[snapshot -i], browser_commands.first.last.last(2)
    toolkit.close
    refute File.exist?(socket_root)
    refute File.exist?(mailbox_root)
    refute File.exist?(File.dirname(downloads))
    assert_empty toolkit.producer_add_dirs
    assert_nil toolkit.producer_permission_arguments
    assert_equal 2, browser_commands.length
    assert_equal "/managed/agent-browser", browser_commands.last.last.first
    assert_equal "close", browser_commands.last.last.last
    end
  end

  def test_visual_preflight_fails_before_the_producer_when_media_tools_are_missing
    entry = FakeBrowser.new(
      cache_root: "/managed/capture-cache",
      agent_browser_cli: "/managed/agent-browser",
      browser_executable: "/managed/chrome",
      agent_browser_version: "0.34.0",
      browsers_path: "/managed/browsers", skills_path: "/managed/skills",
      cache_key: "b" * 64
    )
    bundle = Object.new
    bundle.define_singleton_method(:ensure!) { entry }
    toolkit = Hive::Artifacts::CaptureToolkit.new(
      browser_bundle: bundle,
      runtime_resolver: method(:fake_codex_runtime),
      tool_resolver: ->(name) { name == "ffmpeg" ? "/usr/bin/ffmpeg" : nil }
    )

    error = Dir.mktmpdir("hive-capture-toolkit-missing") do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p(source)
      assert_raises(Hive::ConfigError) do
        toolkit.prepare!(
          kinds: [ "screenshot" ], task_root: root, source_root: source,
          source_sha: "a" * 40, writable_root: File.join(root, "work")
        )
      end
    end
    assert_match(/ffprobe, tesseract/, error.message)
  end

  def test_hive_web_source_starts_controller_managed_server_for_browser_cli
    Dir.mktmpdir("hive-capture-toolkit-web") do |root|
      source = File.join(root, "source")
      %w[bin web web/bin].each { |path| FileUtils.mkdir_p(File.join(source, path)) }
      %w[bin/hive web/Gemfile web/bin/rails].each do |path|
        File.write(File.join(source, path), "fixture")
      end
      entry = FakeBrowser.new(
        cache_root: "/managed/capture-cache",
        agent_browser_cli: "/managed/agent-browser",
        browser_executable: "/managed/browsers/chrome", agent_browser_version: "0.34.0",
        browsers_path: "/managed/browsers", skills_path: "/managed/skills",
        cache_key: "b" * 64
      )
      bundle = Object.new
      bundle.define_singleton_method(:ensure!) { entry }
      tools = %w[ffmpeg ffprobe tesseract env].to_h { |name| [ name, "/usr/bin/#{name}" ] }
      closed = []
      browser_closes = []
      factory = lambda do |**attributes|
        Object.new.tap do |server|
          server.define_singleton_method(:start!) do
            {
              "driver" => "hive-web-capture-runtime", "status" => "ready",
              "app_port" => 45_679, "app_endpoint" => "http://127.0.0.1:45679",
              "hive_home" => File.join(attributes.fetch(:writable_root), "hive-home"),
              "source_sha" => attributes.fetch(:source_sha), "cache_key" => "c" * 64
            }
          end
          server.define_singleton_method(:close) { closed << true }
        end
      end
      toolkit = Hive::Artifacts::CaptureToolkit.new(
        browser_bundle: bundle, tool_resolver: ->(name) { tools[name] },
        web_server_factory: factory,
        runtime_resolver: method(:fake_codex_runtime),
        browser_command_runner: ->(environment, argv) do
          browser_closes << [ environment, argv ]
        end
      )

      receipt = toolkit.prepare!(
        kinds: [ "video" ], task_root: root, source_root: source,
        source_sha: "a" * 40, writable_root: File.join(root, "work")
      )

      assert_equal "ready", receipt.dig("web", "server", "status")
      assert_equal "http://127.0.0.1:45679", receipt.dig("web", "app_endpoint")
      assert_equal receipt.dig("web", "server", "hive_home"),
                   toolkit.launch_environment.fetch("HIVE_EVIDENCE_WEB_HIVE_HOME")
      assert_equal "cli", receipt.dig("web", "interface")
      assert_equal "browser", receipt.dig("web", "argv_prefix").last
      browser_environment = browser_closes.first.first
      assert_match(%r{\A/tmp/hive-browser-state-}, browser_environment.fetch("HOME"))
      refute browser_environment.fetch("HOME").start_with?(File.join(root, "work"))

      toolkit.close
      assert_equal [ true ], closed
      assert_equal 2, browser_closes.length
      assert_equal "open", browser_closes.first.last[-2]
      assert_equal "close", browser_closes.last.last.last
    end
  end

  def test_browser_bootstrap_failure_cleans_the_short_socket_root
    Dir.mktmpdir("hive-capture-toolkit-bootstrap") do |root|
      entry = FakeBrowser.new(
        cache_root: "/managed/capture-cache",
        agent_browser_cli: "/managed/agent-browser",
        browser_executable: "/managed/chrome", agent_browser_version: "0.34.0",
        browsers_path: "/managed/browsers", skills_path: "/managed/skills",
        cache_key: "b" * 64
      )
      bundle = Object.new
      bundle.define_singleton_method(:ensure!) { entry }
      tools = %w[ffmpeg ffprobe tesseract env].to_h { |name| [ name, "/usr/bin/#{name}" ] }
      socket_root = nil
      runner = lambda do |environment, argv|
        socket_root = environment.fetch("AGENT_BROWSER_SOCKET_DIR")
        raise Hive::ConfigError, "bootstrap failed" unless argv.last == "close"
      end
      toolkit = Hive::Artifacts::CaptureToolkit.new(
        browser_bundle: bundle, tool_resolver: ->(name) { tools[name] },
        runtime_resolver: method(:fake_codex_runtime),
        browser_command_runner: runner
      )

      error = assert_raises(Hive::ConfigError) do
        toolkit.prepare!(
          kinds: [ "screenshot" ], task_root: root, source_root: root,
          source_sha: "a" * 40, writable_root: File.join(root, "work")
        )
      end

      assert_equal "bootstrap failed", error.message
      refute File.exist?(socket_root)
    end
  end

  def test_terminal_capture_is_controller_executed_and_receipted
    Dir.mktmpdir("hive-capture-toolkit-terminal") do |root|
      source = File.join(root, "source")
      work = File.join(root, "work")
      FileUtils.mkdir_p(source)
      toolkit = Hive::Artifacts::CaptureToolkit.new(
        runtime_resolver: method(:fake_codex_runtime)
      )
      toolkit.prepare!(
        kinds: [ "terminal" ], task_root: root, source_root: source,
        source_sha: "a" * 40, writable_root: work
      )

      out, = capture_io do
        Hive::Commands::Evidence.new(
          "terminal", "proof", json: true,
          command: [ RbConfig.ruby, "-e", "puts 'captured'" ],
          environment: toolkit.launch_environment
        ).call
      end
      payload = JSON.parse(out)
      candidate = [
        {
          "kind" => "terminal", "representations" => payload.fetch("representations")
        }
      ]
      assert toolkit.verify_captures!(candidate)

      File.open(File.join(root, payload.dig("representations", 1, "path")), "a") do |file|
        file.write("tampered")
      end
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        toolkit.verify_captures!(candidate)
      end
    ensure
      toolkit&.close
    end
  end

  def test_producer_authored_visual_media_without_a_controller_receipt_is_rejected
    Dir.mktmpdir("hive-capture-toolkit-receipt") do |root|
      source = File.join(root, "source")
      work = File.join(root, "work")
      FileUtils.mkdir_p([ source, work ])
      path = File.join(work, "forged.png")
      File.binwrite(path, "not a controller capture")
      toolkit = Hive::Artifacts::CaptureToolkit.new
      toolkit.prepare!(
        kinds: [ "document" ], task_root: root, source_root: source,
        source_sha: "a" * 40, writable_root: work
      )

      error = assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        toolkit.verify_captures!([
          {
            "kind" => "screenshot",
            "representations" => [
              { "path" => "work/forged.png", "media_type" => "image/png" }
            ]
          }
        ])
      end
      assert_match(/no matching controller capture receipt/, error.message)

      provider = {
        "kind" => "screenshot", "summary" => "Forged provider media",
        "claims" => [ "claim-a" ],
        "source" => {
          "type" => "project_provider", "name" => "forged-provider",
          "source_sha" => "a" * 40, "manifest_path" => "work/manifest.json"
        },
        "representations" => [
          {
            "role" => "original", "media_type" => "image/png",
            "path" => "work/forged.png", "bytes" => File.size(path),
            "sha256" => Digest::SHA256.file(path).hexdigest
          },
          {
            "role" => "review", "media_type" => "image/png",
            "path" => "work/other.png", "bytes" => File.size(path),
            "sha256" => Digest::SHA256.file(path).hexdigest
          }
        ]
      }
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        toolkit.verify_captures!([ provider ])
      end
    ensure
      toolkit&.close
    end
  end

  def test_packaged_codex_pin_meets_the_managed_capture_minimum
    dockerfile = File.read(File.expand_path("../../../packaging/docker/Dockerfile", __dir__))

    assert_includes(
      dockerfile,
      "@openai/codex@#{Hive::AgentSupport.for(:codex)::ArtifactPolicy::MINIMUM_VERSION}"
    )
  end

  def test_capture_proxy_maps_only_the_issued_origin_to_the_issued_app_port
    proxy = Hive::Artifacts::CaptureProxy.new
    app = TCPServer.new("127.0.0.1", proxy.app_port)
    request = Queue.new
    app_thread = Thread.new do
      socket = app.accept
      request << socket.readpartial(4096)
      socket.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
      socket.close
    end

    response = proxy_request(proxy.proxy_url, "#{proxy.origin}/health")
    assert_includes response, "200 OK"
    assert response.end_with?("ok")
    forwarded = request.pop
    assert_match %r{\AGET /health HTTP/1\.1\r\n}, forwarded
    assert_includes forwarded, "Host: 127.0.0.1:#{proxy.app_port}\r\n"
    assert_includes forwarded, "Connection: close\r\n"
    refute_includes forwarded, "Host: ignored"

    wrong_port = proxy_request(proxy.proxy_url, "#{proxy.origin}:81/private")
    assert_includes wrong_port, "403 Forbidden"
    loopback = proxy_request(proxy.proxy_url, "http://127.0.0.1/private")
    assert_includes loopback, "403 Forbidden"
  ensure
    proxy&.close
    app&.close
    app_thread&.join(1)
  end

  def test_capture_proxy_preserves_a_validated_websocket_upgrade
    proxy = Hive::Artifacts::CaptureProxy.new
    app = TCPServer.new("127.0.0.1", proxy.app_port)
    request = Queue.new
    app_thread = Thread.new do
      socket = app.accept
      request << socket.readpartial(4096)
      socket.write("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
      socket.close
    end

    response = proxy_request(
      proxy.proxy_url, "#{proxy.origin}/cable",
      headers: "Connection: keep-alive, Upgrade\r\nUpgrade: websocket\r\n"
    )
    assert_includes response, "101 Switching Protocols"
    forwarded = request.pop
    assert_includes forwarded, "Connection: keep-alive, Upgrade\r\n"
    assert_includes forwarded, "Upgrade: websocket\r\n"
    refute_includes forwarded, "Connection: close\r\n"
  ensure
    proxy&.close
    app&.close
    app_thread&.join(1)
  end

  private

  def fake_codex_runtime(profile)
    assert_equal :codex, profile.name
    [ "/managed/codex-runtime" ]
  end

  def proxy_request(proxy_url, target, headers: "Connection: close\r\n")
    proxy_uri = URI.parse(proxy_url)
    socket = TCPSocket.new(proxy_uri.host, proxy_uri.port)
    socket.write("GET #{target} HTTP/1.1\r\nHost: ignored\r\n#{headers}\r\n")
    socket.read
  ensure
    socket&.close
  end
end
