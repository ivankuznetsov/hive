require "json"
require "net/http"
require "securerandom"
require "uri"

module Hive
  class ScreenoteUploader
    DEFAULT_OPEN_TIMEOUT = 10
    DEFAULT_READ_TIMEOUT = 60
    SUCCESS_CODE = "201".freeze

    attr_reader :base_url, :api_token

    def initialize(base_url:, api_token:, http: nil, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT)
      @base_url = base_url.to_s.strip
      @api_token = api_token.to_s.strip
      @http = http || method(:default_request)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def configured?
      !base_url.empty? && !api_token.empty?
    end

    def upload(path:, title:)
      return nil unless configured?
      return nil unless File.file?(path)

      uri = URI("#{base_url.delete_suffix("/")}/api/v1/screenshots")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{api_token}"
      request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
      request.body = multipart_body(path, title.to_s)

      response = @http.call(uri, request, open_timeout: @open_timeout, read_timeout: @read_timeout)
      return parse_success(response) if response.code.to_s == SUCCESS_CODE

      warn "[hive] screenote upload failed for #{File.basename(path)}: HTTP #{response.code}"
      nil
    rescue StandardError => e
      warn "[hive] screenote upload failed for #{File.basename(path)}: #{e.class}: #{e.message}"
      nil
    end

    private

    def boundary
      @boundary ||= "hive-screenote-#{SecureRandom.hex(16)}"
    end

    def multipart_body(path, title)
      body = String.new(encoding: Encoding::BINARY)
      append_field(body, "title", title)
      append_file(body, "image", path)
      body << "--#{boundary}--\r\n"
      body
    end

    def append_field(body, name, value)
      body << "--#{boundary}\r\n"
      body << %(Content-Disposition: form-data; name="#{quote(name)}"\r\n)
      body << "\r\n"
      body << value.to_s
      body << "\r\n"
    end

    def append_file(body, name, path)
      filename = File.basename(path)
      body << "--#{boundary}\r\n"
      body << %(Content-Disposition: form-data; name="#{quote(name)}"; filename="#{quote(filename)}"\r\n)
      body << "Content-Type: #{content_type(path)}\r\n"
      body << "\r\n"
      body << File.binread(path)
      body << "\r\n"
    end

    def quote(value)
      value.to_s.gsub("\\", "\\\\").gsub('"', '\"')
    end

    def content_type(path)
      case File.extname(path).downcase
      when ".jpg", ".jpeg" then "image/jpeg"
      else "image/png"
      end
    end

    def parse_success(response)
      payload = JSON.parse(response.body.to_s)
      url = payload["annotate_url"].to_s
      return nil if url.empty?

      {
        "annotate_url" => url,
        "screenshot_id" => payload["screenshot_id"]
      }
    rescue JSON::ParserError => e
      warn "[hive] screenote upload returned invalid JSON: #{e.message}"
      nil
    end

    def default_request(uri, request, open_timeout:, read_timeout:)
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
                                              open_timeout: open_timeout,
                                              read_timeout: read_timeout) do |http|
        http.request(request)
      end
    end
  end
end
