# Be sure to restart your server when you modify this file.

# Version of your assets, change this if you want to expire all your assets.
Rails.application.config.assets.version = "1.0"

# Supervised worktree capture must not write compiled assets into the linked
# source checkout. Propshaft accepts an absolute output path; the capture
# runtime owns and removes this private directory with the server lifecycle.
if (capture_assets = ENV["HIVE_WEB_ASSETS_DIR"].to_s.strip).present?
  Rails.application.config.assets.output_path = Pathname(capture_assets)
end

# Add additional assets to the asset load path.
# Rails.application.config.assets.paths << Emoji.images_path
