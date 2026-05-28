# frozen_string_literal: true

require "net/http"
require "uri"
require "tempfile"

module Jobs
  # Scan a post's raw for image URLs pointing at the openscholay upstream and
  # replace each with a local Discourse upload. Idempotent — already-local
  # `upload://...` references are skipped because the pattern only matches the
  # configured upstream base URL.
  class MinicodNavPullImages < ::Jobs::Base
    READ_TIMEOUT = 30
    OPEN_TIMEOUT = 10
    MAX_BYTES = 20 * 1024 * 1024

    def execute(args)
      post = Post.find_by(id: args[:post_id])
      return unless post

      base_url = SiteSetting.minicodnav_openscholay_base_url.to_s.presence
      return if base_url.blank?

      pattern = %r{!\[([^\]]*)\]\((#{Regexp.escape(base_url)}[^\s)]+)\)}

      new_raw = post.raw.dup
      changed = false

      new_raw.gsub!(pattern) do |match|
        alt = Regexp.last_match(1)
        url = Regexp.last_match(2)

        upload = pull(url, post.user_id)
        if upload&.persisted?
          changed = true
          "![#{alt}](#{upload.short_url})"
        else
          match
        end
      end

      return unless changed

      post.update_columns(raw: new_raw, cooked: "")
      post.rebake!
    end

    private

    def pull(url, user_id)
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
      return nil if response.body.bytesize > MAX_BYTES

      basename = File.basename(uri.path)
      basename = "image" if basename.blank?
      tempfile = Tempfile.new(["minicodnav", File.extname(basename)])
      tempfile.binmode
      tempfile.write(response.body)
      tempfile.rewind

      owner = user_id || Discourse.system_user.id
      UploadCreator.new(tempfile, basename, origin: url).create_for(owner)
    rescue StandardError => e
      Rails.logger.warn("[minicodnav] image pull failed: #{url} #{e.class}: #{e.message}")
      nil
    ensure
      tempfile&.close!
    end
  end
end
