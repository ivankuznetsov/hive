require "uri"
require "hive/tui/text"

module Hive
  module Tui
    module Views
      module Hyperlink
        module_function

        def osc8(visible, url, enabled:)
          label = visible.to_s
          return label unless enabled

          href = Hive::Tui::Text.sanitize(url).strip
          return label unless valid_http_url?(href)

          "\e]8;;#{href}\e\\#{label}\e]8;;\e\\"
        end

        def valid_http_url?(url)
          uri = URI.parse(url)
          uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
        rescue URI::InvalidURIError
          false
        end
        private_class_method :valid_http_url?
      end
    end
  end
end
