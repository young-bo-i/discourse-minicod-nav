# frozen_string_literal: true

require "net/http"
require "uri"
require "tempfile"

module Jobs
  # Rehost upstream assets referenced by a post into local Discourse uploads:
  #   - Inline images:  ![alt](upstream/uploads/foo.png) → ![alt](upload://<sha>.png)
  #   - PDF file_url:   bare upstream URL on its own line → [name.pdf|attachment](upload://<sha>.pdf)
  #
  # The attachment form for the PDF matches what the official
  # discourse-pdf-previews theme component needs to trigger inline rendering;
  # without rehosting, a bare external URL would never be previewed (the
  # component only accepts upload://...).
  class MinicodNavPullAssets < ::Jobs::Base
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 60
    MAX_IMAGE_BYTES = 20 * 1024 * 1024
    MAX_PDF_BYTES = 60 * 1024 * 1024

    def execute(args)
      post = Post.find_by(id: args[:post_id])
      return unless post

      base_url = SiteSetting.minicodnav_openscholay_base_url.to_s.presence
      return if base_url.blank?

      new_raw = post.raw.dup
      changed = false

      image_pattern = %r{!\[([^\]]*)\]\((#{Regexp.escape(base_url)}[^\s)]+)\)}
      new_raw.gsub!(image_pattern) do |match|
        alt = Regexp.last_match(1)
        url = Regexp.last_match(2)

        upload = pull(url, post.user_id, MAX_IMAGE_BYTES)
        if upload&.persisted?
          changed = true
          "![#{alt}](#{upload.short_url})"
        else
          match
        end
      end

      pdf_url = args[:pdf_url].to_s
      if pdf_url.present? && pdf_url.start_with?(base_url) && new_raw.include?(pdf_url)
        upload = pull(pdf_url, post.user_id, MAX_PDF_BYTES)
        if upload&.persisted?
          basename = File.basename(URI.parse(pdf_url).path)
          basename = "paper.pdf" if basename.blank?
          new_raw.sub!(pdf_url, "[#{basename}|attachment](#{upload.short_url})")
          changed = true
        end
      end

      return unless changed

      post.update_columns(raw: new_raw, cooked: "")
      post.rebake!
    end

    private

    def pull(url, user_id, max_bytes)
      uri = URI.parse(url)
      return nil unless uri.is_a?(URI::HTTP)

      response = nil
      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT,
      ) { |http| response = http.get(uri.request_uri) }

      return nil unless response.is_a?(Net::HTTPSuccess)
      return nil if response.body.bytesize > max_bytes

      basename = File.basename(uri.path)
      basename = "asset" if basename.blank?
      tempfile = Tempfile.new(["minicodnav", File.extname(basename)])
      tempfile.binmode
      tempfile.write(response.body)
      tempfile.rewind

      owner = user_id || Discourse.system_user.id
      UploadCreator.new(tempfile, basename, origin: url).create_for(owner)
    rescue StandardError => e
      Rails.logger.warn("[minicodnav] asset pull failed: #{url} #{e.class}: #{e.message}")
      nil
    ensure
      tempfile&.close!
    end
  end
end
