class IdeasController < ApplicationController
  MAX_IMAGES = 8
  MAX_IMAGE_BYTES = 10 * 1024 * 1024

  # Creates a task in 1-inbox via the same Commands::New the CLI and TUI
  # use. Images arrive as multipart uploads named like the [imageN]
  # placeholders the composer spliced into the text; they land in the
  # task's assets/ dir (the TUI's exact contract).
  def create
    project = find_project!(params.require(:project))
    project.add_idea!(params.require(:text), attachments: staged_attachments)
    redirect_back_or_to root_path, allow_other_host: false, notice: "Idea added to #{project.name}"
  end

  private

  # Uploaded files come as images[] with original filenames already set to
  # their placeholder names (image1.png, ...) by the composer Stimulus
  # controller. Re-derive safe names server-side anyway: the placeholder
  # index from the client is untrusted input.
  def staged_attachments
    files = Array(params[:images]).reject(&:blank?)
    raise Hive::Error, "too many images (max #{MAX_IMAGES})" if files.size > MAX_IMAGES

    files.each_with_index.map do |file, i|
      raise Hive::Error, "image #{i + 1} is too large (max 10 MB)" if file.size > MAX_IMAGE_BYTES

      ext = File.extname(file.original_filename.to_s).downcase
      ext = ".png" unless /\A\.[a-z0-9]{1,5}\z/.match?(ext)
      base = File.basename(file.original_filename.to_s, ".*")
      name = /\Aimage\d{1,3}\z/.match?(base) ? "#{base}#{ext}" : "image#{i + 1}#{ext}"
      [ file.tempfile.path, name ]
    end
  end
end
