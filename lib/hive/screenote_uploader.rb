require "json"
require "net/http"
require "securerandom"
require "uri"

module Hive
  class ScreenoteUploader
    DEFAULT_OPEN_TIMEOUT = 10
    DEFAULT_READ_TIMEOUT = 60
    # Screenote signals a created screenshot with 201 specifically; a bare
    # 200 OK would be treated as a failure here. This pins the external API's
    # success contract — widen only if screenote starts returning other 2xx
    # codes on a successful create.
    SUCCESS_CODE = "201".freeze

    attr_reader :base_url

    # `http:` injects the transport seam (defaults to Net::HTTP). It is called
    # as `http.call(uri, request, open_timeout:, read_timeout:)` and must return
    # a response that duck-types Net::HTTPResponse: `#code` -> String (e.g.
    # "201") and `#body` -> String (the JSON payload). The test suite passes a
    # lambda returning a Struct with those two readers.
    def initialize(base_url:, api_token:, http: nil, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT)
      @base_url = base_url.to_s.strip
      @api_token = api_token.to_s.strip
      @http = http || method(:default_request)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def configured?
      !base_url.empty? && !@api_token.empty?
    end

    def upload(path:, title:)
      return nil unless configured?
      return nil unless File.file?(path)

      uri = URI("#{base_url.delete_suffix("/")}/api/v1/screenshots")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@api_token}"
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
      # `body` is BINARY-encoded; a UTF-8 title (em-dash, curly quotes,
      # accented or Cyrillic captions, emoji) would flip its encoding to UTF-8
      # and then make the later `body << File.binread(path)` raise
      # Encoding::CompatibilityError. Force the title bytes to binary so any
      # caption appends cleanly.
      body << value.to_s.b
      body << "\r\n"
    end

    def append_file(body, name, path)
      filename = File.basename(path)
      body << "--#{boundary}\r\n"
      # `.b` mirrors the title fix in append_field: a non-ASCII on-disk filename
      # interpolated into the BINARY buffer would flip its encoding to UTF-8 and
      # then raise Encoding::CompatibilityError when the image bytes append.
      # (Unreachable in production — SCREENOTE_FILENAME_RE gates `[\w.-]` — but
      # the standalone class must stay robust on its own.)
      body << %(Content-Disposition: form-data; name="#{quote(name)}"; filename="#{quote(filename)}"\r\n).b
      body << "Content-Type: #{content_type(path)}\r\n"
      body << "\r\n"
      body << File.binread(path)
      body << "\r\n"
    end

    def quote(value)
      # Backslash-escape both the escape character and the quote so an exotic
      # on-disk filename can't break out of the Content-Disposition value. Use
      # the block form, not a replacement string: gsub's replacement string
      # gives "\\" a special meaning and would collapse the backslash escape,
      # leaving the quote escaped but the backslash silently dropped.
      value.to_s.gsub(/[\\"]/) { |char| "\\#{char}" }
    end

    def content_type(path)
      case File.extname(path).downcase
      when ".jpg", ".jpeg" then "image/jpeg"
      else "image/png"
      end
    end

    def parse_success(response)
      payload = JSON.parse(response.body.to_s)
      unless payload.is_a?(Hash)
        warn "[hive] screenote upload returned a non-object response body"
        return nil
      end

      url = payload["annotate_url"].to_s
      if url.empty?
        # A 201 Created carrying no annotate_url is a screenote contract break,
        # not "screenote disabled" — and it looks identical to the disabled
        # case from the caller. Warn so it's distinguishable; every other
        # anomaly branch in this method already does.
        warn "[hive] screenote upload returned a 201 with a blank annotate_url"
        return nil
      end
      unless url.match?(%r{\Ahttps?://})
        warn "[hive] screenote upload returned a non-http annotate_url: #{url.inspect}"
        return nil
      end

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
