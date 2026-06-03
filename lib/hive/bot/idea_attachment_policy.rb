require "hive/tui/composer_staging"

module Hive
  module Bot
    module IdeaAttachmentPolicy
      ALLOWED_EXTENSIONS = %w[jpg jpeg png webp gif pdf txt md docx].freeze
      MIME_EXTENSION = {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/webp" => "webp",
        "image/gif" => "gif",
        "application/pdf" => "pdf",
        "text/plain" => "txt",
        "text/markdown" => "md",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => "docx"
      }.freeze

      Result = Struct.new(:status, :file_id, :file_size, :ext, :dest_basename, keyword_init: true)

      module_function

      def classify(update, draft, max_bytes:, max_count:)
        return Result.new(status: :cap_reached) if Array(draft&.attachments).size >= max_count.to_i

        item = media_item(update)
        ext = item[:ext]
        return Result.new(status: :disallowed_type) unless allowed_extension?(ext)

        size = item[:file_size].to_i
        return Result.new(status: :too_large, file_size: size) if size.positive? && size > max_bytes.to_i

        Result.new(
          status: :ok,
          file_id: item[:file_id],
          file_size: item[:file_size],
          ext: Hive::Tui::ComposerStaging.normalized_extension(ext),
          dest_basename: item[:file_name]
        )
      end

      def image_extension?(ext)
        %w[jpg jpeg png webp gif].include?(ext.to_s.downcase.delete_prefix("."))
      end

      def allowed_extension?(ext)
        ALLOWED_EXTENSIONS.include?(Hive::Tui::ComposerStaging.normalized_extension(ext))
      end

      def media_item(update)
        if update.photo
          return {
            file_id: update.photo[:file_id],
            file_size: update.photo[:file_size],
            ext: "jpg",
            file_name: "photo.jpg"
          }
        end

        document = update.document || {}
        file_name = document[:file_name].to_s
        ext = File.extname(file_name).delete_prefix(".")
        ext = MIME_EXTENSION[document[:mime_type].to_s] if ext.empty?
        {
          file_id: document[:file_id],
          file_size: document[:file_size],
          ext: ext,
          file_name: file_name
        }
      end
    end
  end
end
