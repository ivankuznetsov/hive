require "uri"
require "hive/pr"

module Hive
  module Bot
    module Format
      module_function

      def html_escape(text)
        text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
      end

      def html_attr_escape(text)
        html_escape(text).gsub('"', "&quot;")
      end

      def html_pr_link(url)
        clean_url = strip_control_chars(url).strip
        number = Hive::Pr.number(clean_url)
        return nil unless number && valid_http_url?(clean_url)

        %(<a href="#{html_attr_escape(clean_url)}">#{html_escape(number)}</a>)
      end

      def valid_http_url?(url)
        uri = URI.parse(url)
        uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
      rescue URI::InvalidURIError
        false
      end

      def strip_control_chars(text)
        text.to_s.gsub(/[\x00-\x1f\x7f]/, "")
      end
    end
  end
end
