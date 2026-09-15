# json 3 makes parser options keyword-only, while Rails 8.1.3.1 still passes
# ActiveSupport::JSON.decode options positionally. Cookie/session decoding uses
# that method, so retain Rails' existing date-conversion behavior with keywords.
if JSON::VERSION.split(".").first.to_i >= 3
  module ActiveSupportJson3Compatibility
    def decode(json, options = {})
      data = ::JSON.parse(json, **options)
      ActiveSupport.parse_json_times ? convert_dates_from(data) : data
    end
  end

  ActiveSupport::JSON.singleton_class.prepend(ActiveSupportJson3Compatibility)
end
