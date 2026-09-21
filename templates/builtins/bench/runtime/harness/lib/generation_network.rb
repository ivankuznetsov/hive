# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "uri"

module HiveBench
  # Optional transport provisioning only. Hive still owns every task transition.
  # Existing resources are never replaced, relabeled, or disconnected.
  class GenerationNetwork
    LABEL = "ai.hive.bench.campaign"
    CONFIG_LABEL = "ai.hive.bench.network-config"
    SCRIPT = File.expand_path("provider_egress_proxy.rb", __dir__)
    TARGET = "/opt/bench-provider-proxy.rb"

    def self.prepare!(campaign, command: Open3.method(:capture3))
      return unless campaign.fetch("isolation", {})["managed_network"] == true

      new(campaign, command).prepare!
    end

    def initialize(campaign, command)
      @command = command
      isolation = campaign.fetch("isolation")
      @campaign = campaign["campaign_id"]
      @network = isolation["docker_network"]
      @image = isolation["proxy_image"]
      @hosts = isolation["provider_hosts"]
      proxy = URI.parse(isolation.fetch("https_proxy", ""))
      @proxy = proxy.host
      @port = proxy.port
      valid = @campaign.is_a?(String) && @campaign.match?(/\A[a-z0-9][a-z0-9-]{0,63}\z/) &&
        isolation["require_provider_egress"] == true &&
        @network.is_a?(String) && @network.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/) &&
        proxy.to_s == "http://#{@proxy}:#{@port}" && safe_name?(@proxy) &&
        @port.between?(1024, 65_535) && @network != @proxy &&
        @image.is_a?(String) && @image.match?(/\A(?:[a-zA-Z0-9][a-zA-Z0-9._\/:\-]*@)?sha256:[a-f0-9]{64}\z/) &&
        @hosts.is_a?(Array) && !@hosts.empty? && @hosts.all? { |host| provider_host?(host) }
      raise ArgumentError, "invalid managed benchmark network configuration" unless valid

      @hosts = @hosts.uniq.sort
      @env = ["HB_PROXY_ALLOW_HOSTS=#{@hosts.join(',')}", "HB_PROXY_PORT=#{@port}"]
      @labels = { LABEL => @campaign, CONFIG_LABEL => Digest::SHA256.hexdigest(
        JSON.generate([@network, @proxy, @port, @hosts, @image, Digest::SHA256.file(SCRIPT).hexdigest])
      ) }
    rescue URI::InvalidURIError
      raise ArgumentError, "invalid managed benchmark proxy URL"
    end

    def prepare!
      # Inspect both names before creating anything: name collisions are not ours.
      network = inspect_resource("network", @network)
      proxy = inspect_resource("container", @proxy)
      validate_network!(network) if network
      validate_proxy!(proxy) if proxy

      unless network
        run!("network", "create", "--internal", *label_args, @network)
      end
      unless proxy
        run!("create", "--name", @proxy, *label_args,
             "--network=bridge", "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges",
             "--user=65534:65534", "--entrypoint=ruby",
             "--mount", "type=bind,src=#{SCRIPT},dst=#{TARGET},readonly",
             *@env.flat_map { |value| ["--env", value] }, @image, TARGET)
      end
      networks = proxy&.dig("NetworkSettings", "Networks") || {}
      run!("network", "connect", @network, @proxy) unless networks.key?(@network)
      run!("start", @proxy) unless proxy&.dig("State", "Running") == true
      true
    end

    private

    def safe_name?(name)
      name.is_a?(String) && name.match?(/\A[a-zA-Z][a-zA-Z0-9-]{0,62}\z/) && name != "localhost"
    end

    def provider_host?(host)
      return false unless host.is_a?(String) && host.size <= 253

      labels = host.split(".", -1)
      labels.size >= 2 && labels.last.match?(/\A[a-z]{2,63}\z/) &&
        labels.all? { |label| label.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/) } &&
        !host.match?(/(?:\A|\.)(?:localhost|local|github\.com|githubusercontent\.com|githubassets\.com)\z/)
    end

    def label_args
      @labels.flat_map { |key, value| ["--label", "#{key}=#{value}"] }
    end

    def validate_labels!(labels)
      unless labels.is_a?(Hash) && @labels.all? { |key, value| labels[key] == value }
        raise ArgumentError, "managed benchmark resource is unowned or its configuration changed"
      end
    end

    def validate_network!(network)
      validate_labels!(network["Labels"])
      peers = network.fetch("Containers", {}).values.map { |peer| peer["Name"] }
      unless network["Internal"] == true && network["Driver"] == "bridge" && (peers - [@proxy]).empty?
        raise ArgumentError, "managed benchmark network must be internal with only its proxy attached"
      end
    end

    def validate_proxy!(proxy)
      config = proxy.fetch("Config", {})
      host = proxy.fetch("HostConfig", {})
      validate_labels!(config["Labels"])
      networks = proxy.dig("NetworkSettings", "Networks") || {}
      mount = proxy.fetch("Mounts", [])
      valid = config["Image"] == @image && config["Entrypoint"] == ["ruby"] &&
        config["Cmd"] == [TARGET] && config["User"] == "65534:65534" &&
        @env.all? { |value| config.fetch("Env", []).include?(value) } &&
        host["ReadonlyRootfs"] == true && host["Privileged"] == false &&
        host.fetch("PortBindings", {}).to_h.empty? && host["PublishAllPorts"] == false &&
        host["NetworkMode"] == "bridge" &&
        host.fetch("CapDrop", []).include?("ALL") &&
        host.fetch("SecurityOpt", []).include?("no-new-privileges") &&
        (networks.keys - ["bridge", @network]).empty? && networks.key?("bridge") &&
        mount.size == 1 && mount[0]["Source"] == SCRIPT && mount[0]["Destination"] == TARGET &&
        mount[0]["Type"] == "bind" && mount[0]["RW"] == false
      raise ArgumentError, "managed benchmark proxy configuration does not match campaign" unless valid
    end

    def inspect_resource(kind, name)
      out, err, status = @command.call("docker", kind, "inspect", name)
      unless success?(status)
        return nil if err.match?(/No such (?:network|container|object):/i)
        return nil if kind == "network" && err.strip == "Error response from daemon: network #{name} not found"

        raise ArgumentError, "cannot inspect benchmark #{kind}: #{err.strip}"
      end
      parsed = JSON.parse(out)
      unless parsed.is_a?(Array) && parsed.size == 1 && parsed.first.is_a?(Hash)
        raise ArgumentError, "invalid Docker inspect output for benchmark #{kind}"
      end
      parsed.first
    rescue JSON::ParserError
      raise ArgumentError, "invalid Docker inspect output for benchmark #{kind}"
    end

    def success?(status)
      status.respond_to?(:success?) ? status.success? : status == true
    end

    def run!(*args)
      _out, err, status = @command.call("docker", *args)
      raise ArgumentError, "benchmark network setup failed: #{err.strip}" unless success?(status)
    end
  end
end
