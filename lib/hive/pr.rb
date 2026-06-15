require "uri"

module Hive
  # PR-URL helpers shared by every surface that displays a pull-request
  # link: the `hive status` command, the TUI tasks pane, and the Telegram
  # bot. Keeping `number`/`valid_http_url?` here is what stops those
  # surfaces from drifting apart on how a PR number is parsed or which
  # hrefs are considered safe.
  module Pr
    module_function

    # Extract the `#NNN` PR number from a GitHub pull-request URL, or nil
    # when the URL is missing or not a `/pull/<digits>` URL.
    def number(url)
      match = url.to_s.strip.match(%r{(?:\A|/)pull/(\d+)/?(?:[?#].*)?\z})
      match ? "##{match[1]}" : nil
    end

    # Injection-gating predicate shared by the OSC 8 (TUI) and HTML (bot)
    # link builders: true only for a parseable http(s) URL with a non-empty
    # host. This is the check that rejects `javascript:` and other non-http
    # schemes, so a future hardening (e.g. host allow-listing) tightens both
    # link surfaces at once instead of one silently lagging the other.
    def valid_http_url?(url)
      uri = URI.parse(url)
      uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
    rescue URI::InvalidURIError
      false
    end
  end
end
