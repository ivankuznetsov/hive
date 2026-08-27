#!/usr/bin/env ruby
# frozen_string_literal: true

# Minimal CONNECT proxy for benchmark generation containers. Run this in a
# dual-homed container: the ordinary bridge supplies outbound access and a
# Docker --internal network supplies the only candidate-visible peer. Only
# explicitly listed provider hosts may be tunneled; GitHub and arbitrary IPs
# receive 403 before any upstream socket is opened.

require "socket"
require "time"

HOST = ENV.fetch("HB_PROXY_BIND", "0.0.0.0")
PORT = Integer(ENV.fetch("HB_PROXY_PORT", "3128"), 10)
ALLOWED = ENV.fetch("HB_PROXY_ALLOW_HOSTS", "openrouter.ai")
             .split(",").map { |host| host.strip.downcase }.reject(&:empty?).uniq.freeze
MAX_HEADER_BYTES = 16_384
MAX_HEADER_LINES = 100

abort "HB_PROXY_ALLOW_HOSTS must name at least one host" if ALLOWED.empty?
abort "invalid provider allowlist host" unless ALLOWED.all? { |host| host.match?(/\A[a-z0-9][a-z0-9.-]*[a-z0-9]\z/) }

def audit(message)
  $stdout.puts("#{Time.now.utc.iso8601} #{message}")
  $stdout.flush
end

def reject(client, status, message)
  body = "#{message}\n"
  client.write(
    "HTTP/1.1 #{status}\r\nConnection: close\r\n" \
    "Content-Type: text/plain\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
  )
rescue IOError, SystemCallError
  nil
end

def read_request(client)
  bytes = 0
  lines = []
  MAX_HEADER_LINES.times do
    line = client.gets
    return if line.nil?

    bytes += line.bytesize
    return if bytes > MAX_HEADER_BYTES

    lines << line
    return lines if line == "\r\n" || line == "\n"
  end
  nil
end

def tunnel(client, upstream)
  client.write("HTTP/1.1 200 Connection Established\r\n\r\n")
  pumps = [
    Thread.new { IO.copy_stream(client, upstream) rescue nil; upstream.close_write rescue nil },
    Thread.new { IO.copy_stream(upstream, client) rescue nil; client.close_write rescue nil }
  ]
  pumps.each(&:join)
end

server = TCPServer.new(HOST, PORT)
audit("provider-egress-proxy ready port=#{PORT} allow=#{ALLOWED.join(",")}")

loop do
  client = server.accept
  Thread.new(client) do |socket|
    begin
      request = read_request(socket)
      unless request
        reject(socket, "400 Bad Request", "invalid request")
        next
      end

      method, authority, version = request.first.to_s.strip.split(/\s+/, 3)
      host, port = authority.to_s.split(":", 2)
      host = host.to_s.downcase
      unless method == "CONNECT" && version&.start_with?("HTTP/") && port == "443" && ALLOWED.include?(host)
        audit("deny method=#{method.inspect} authority=#{authority.inspect}")
        reject(socket, "403 Forbidden", "destination denied")
        next
      end

      audit("allow host=#{host} port=443")
      upstream = Socket.tcp(host, 443, connect_timeout: 15)
      tunnel(socket, upstream)
    rescue StandardError => error
      audit("error class=#{error.class}")
      reject(socket, "502 Bad Gateway", "provider unavailable")
    ensure
      upstream&.close rescue nil
      socket.close rescue nil
    end
  end
end
