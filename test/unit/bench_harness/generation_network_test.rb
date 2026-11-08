# frozen_string_literal: true

require "test_helper"
require_relative "../../../templates/builtins/bench/runtime/harness/lib/generation_network"

class BenchGenerationNetworkTest < Minitest::Test
  def campaign
    { "campaign_id" => "portable-test", "isolation" => {
      "managed_network" => true, "require_provider_egress" => true,
      "docker_network" => "bench-test", "https_proxy" => "http://bench-proxy:3128",
      "provider_hosts" => [ "api.z.ai", "openrouter.ai" ],
      "proxy_image" => "sha256:#{'a' * 64}"
    } }
  end

  class Docker
    attr_reader :calls, :resources

    def initialize
      @calls = []
      @resources = {}
    end

    def call(*argv)
      @calls << argv
      kind, action, name = argv[1..3]
      if action == "inspect"
        value = @resources[[ kind, name ]]
        return [ JSON.generate([ value ]), "", true ] if value

        return [ "", "Error response from daemon: network #{name} not found", false ] if kind == "network"

        return [ "", "Error: No such #{kind}: #{name}", false ]
      end
      [ "created", "", true ]
    end
  end

  def test_opt_in_only
    docker = Docker.new
    HiveBench::GenerationNetwork.prepare!({}, command: docker)
    assert_empty docker.calls
  end

  def test_creates_internal_network_and_unpublished_dual_homed_proxy
    docker = Docker.new
    HiveBench::GenerationNetwork.prepare!(campaign, command: docker)
    create = docker.calls.find { |args| args[1..2] == %w[network create] }
    assert_includes create, "--internal"
    run = docker.calls.find { |args| args[1] == "create" }
    assert_includes run, "--read-only"
    assert_includes run, "HB_PROXY_ALLOW_HOSTS=api.z.ai,openrouter.ai"
    assert_includes run, "--network=bridge"
    refute run.any? { |arg| arg.start_with?("--publish", "-p=") }
    assert_includes docker.calls, %w[docker network connect bench-test bench-proxy]
    assert_includes docker.calls, %w[docker start bench-proxy]
  end

  def test_invalid_configuration_does_not_touch_docker
    [ { "proxy_image" => "runner:latest" }, { "provider_hosts" => [ "127.0.0.1" ] },
      { "provider_hosts" => [ "github.com" ] }, { "provider_hosts" => [ "*.z.ai" ] },
      { "https_proxy" => "http://user:secret@proxy:3128" },
      { "https_proxy" => "http://proxy:65536" }, { "docker_network" => "--host" },
      { "require_provider_egress" => false } ].each do |values|
      data = campaign
      data["isolation"].merge!(values)
      docker = Docker.new
      assert_raises(ArgumentError) { HiveBench::GenerationNetwork.prepare!(data, command: docker) }
      assert_empty docker.calls
    end
  end

  def test_refuses_existing_unowned_network_before_mutating
    docker = Docker.new
    docker.resources[[ "network", "bench-test" ]] = { "Internal" => true, "Labels" => {}, "Containers" => {} }
    assert_raises(ArgumentError) { HiveBench::GenerationNetwork.prepare!(campaign, command: docker) }
    assert docker.calls.all? { |args| args[2] == "inspect" }
  end

  def test_docker_permission_error_is_not_treated_as_missing_resource
    calls = []
    command = ->(*args) { calls << args; [ "", "permission denied", false ] }
    assert_raises(ArgumentError) { HiveBench::GenerationNetwork.prepare!(campaign, command: command) }
    assert_equal 1, calls.size
  end

  def installed_docker(running: true, connected: true)
    docker = Docker.new
    HiveBench::GenerationNetwork.prepare!(campaign, command: docker)
    create = docker.calls.find { |args| args[1] == "create" }
    labels = create.each_cons(2).filter_map { |key, value| value.split("=", 2) if key == "--label" }.to_h
    env = create.each_cons(2).filter_map { |key, value| value if key == "--env" }
    network = { "Internal" => true, "Driver" => "bridge", "Labels" => labels,
                "Containers" => connected ? { "proxy-id" => { "Name" => "bench-proxy" } } : {} }
    proxy = {
      "Config" => { "Labels" => labels, "Image" => campaign["isolation"]["proxy_image"],
                    "Entrypoint" => [ "ruby" ], "Cmd" => [ HiveBench::GenerationNetwork::TARGET ],
                    "User" => "65534:65534", "Env" => env },
      "HostConfig" => { "ReadonlyRootfs" => true, "Privileged" => false, "PortBindings" => {}, "PublishAllPorts" => false,
                        "NetworkMode" => "bridge", "CapDrop" => [ "ALL" ], "SecurityOpt" => [ "no-new-privileges" ] },
      "Mounts" => [ { "Source" => HiveBench::GenerationNetwork::SCRIPT,
                     "Destination" => HiveBench::GenerationNetwork::TARGET, "Type" => "bind", "RW" => false } ],
      "NetworkSettings" => { "Networks" => connected ? { "bridge" => {}, "bench-test" => {} } : { "bridge" => {} } },
      "State" => { "Running" => running }
    }
    docker.resources[[ "network", "bench-test" ]] = network
    docker.resources[[ "container", "bench-proxy" ]] = proxy
    docker.calls.clear
    docker
  end

  def test_matching_running_resources_are_only_inspected
    docker = installed_docker
    HiveBench::GenerationNetwork.prepare!(campaign, command: docker)
    assert_equal [ %w[docker network inspect bench-test], %w[docker container inspect bench-proxy] ], docker.calls
  end

  def test_partial_owned_setup_can_be_resumed_without_recreation
    docker = installed_docker(running: false, connected: false)
    HiveBench::GenerationNetwork.prepare!(campaign, command: docker)
    assert_equal [ %w[docker network connect bench-test bench-proxy], %w[docker start bench-proxy] ], docker.calls.drop(2)
  end

  def test_refuses_external_peers_and_modified_owned_proxy
    mutations = [
      ->(d) { d.resources[[ "network", "bench-test" ]]["Containers"]["cell"] = { "Name" => "candidate" } },
      ->(d) { d.resources[[ "network", "bench-test" ]]["Internal"] = false },
      ->(d) { d.resources[[ "container", "bench-proxy" ]]["HostConfig"]["PortBindings"] = { "3128/tcp" => [ {} ] } },
      ->(d) { d.resources[[ "container", "bench-proxy" ]]["NetworkSettings"]["Networks"]["unrelated"] = {} },
      ->(d) { d.resources[[ "container", "bench-proxy" ]]["Config"]["Env"] = [] }
    ]
    mutations.each do |change|
      docker = installed_docker
      change.call(docker)
      assert_raises(ArgumentError) { HiveBench::GenerationNetwork.prepare!(campaign, command: docker) }
      assert docker.calls.all? { |args| args[2] == "inspect" }
    end
  end
end
