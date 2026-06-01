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
  #
  # Performance characteristics:
  #   - queue: ultra_low so this never blocks PostAlert / ProcessPost / etc.
  #   - DistributedMutex per post_id: a post updated 5 times in 30s will not
  #     spawn 5 simultaneous downloads of the same PDF; the second job through
  #     the mutex sees the rewritten raw and bails.
  #   - Streamed HTTP read: response body is written chunk-by-chunk into a
  #     tempfile with a hard cap; we never hold the full file in RAM.
  #   - One persistent HTTP connection per upstream host across all assets of
  #     a single post, so K screenshots from the same host = 1 TLS handshake.
  class MinicodNavPullAssets < ::Jobs::Base
    sidekiq_options queue: "ultra_low"

    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 60
    MAX_IMAGE_BYTES = 20 * 1024 * 1024
    MAX_PDF_BYTES = 60 * 1024 * 1024
    CHUNK_SIZE = 64 * 1024
    MAX_REDIRECTS = 3

    class AssetTooBig < StandardError
    end
    class AssetFetchFailed < StandardError
    end

    def execute(args)
      post_id = args[:post_id].to_i
      return if post_id <= 0

      base_url = SiteSetting.minicodnav_openscholay_base_url.to_s.presence
      return if base_url.blank?

      DistributedMutex.synchronize("minicod_nav_pull_assets_#{post_id}", validity: 10.minutes) do
        run(post_id, base_url, args[:pdf_url].to_s)
      end
    end

    private

    def run(post_id, base_url, pdf_url)
      post = Post.find_by(id: post_id)
      return unless post

      new_raw = post.raw.dup
      changed = false
      @http_pool = {}

      begin
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

        if pdf_url.present? && pdf_url.start_with?(base_url) && new_raw.include?(pdf_url)
          upload = pull(pdf_url, post.user_id, MAX_PDF_BYTES)
          if upload&.persisted?
            basename = File.basename(URI.parse(pdf_url).path)
            basename = "paper.pdf" if basename.blank?
            new_raw.sub!(pdf_url, "[#{basename}|attachment](#{upload.short_url})")
            changed = true
          end
        end
      ensure
        @http_pool.each_value do |h|
          begin
            h.finish
          rescue StandardError
            nil
          end
        end
      end

      return unless changed

      # Avoid the cooked: "" + rebake! double-write pattern. rebake! overwrites
      # cooked anyway, and zeroing it leaves a millisecond window where the post
      # renders as empty. update_columns(raw:) skips callbacks (no cascading
      # ProcessPost) and rebake! handles re-cooking.
      post.update_columns(raw: new_raw)
      post.rebake!
    end

    def pull(url, user_id, max_bytes)
      current_url = url
      final_uri = nil
      tempfile = nil

      (MAX_REDIRECTS + 1).times do |hop|
        uri = URI.parse(current_url)
        unless uri.is_a?(URI::HTTP)
          Rails.logger.warn("[minicodnav] asset pull #{url}: non-http URI after #{hop} hops (#{current_url})")
          return nil
        end

        redirect_target = nil

        http_for(uri).request(Net::HTTP::Get.new(uri.request_uri)) do |response|
          case response
          when Net::HTTPSuccess
            tempfile = stream_to_tempfile(response, uri, max_bytes)
            final_uri = uri
          when Net::HTTPRedirection
            redirect_target = response["location"]
          else
            Rails.logger.warn(
              "[minicodnav] asset #{url}: HTTP #{response.code} #{response.message}" \
                "#{hop.positive? ? " after #{hop} redirect(s)" : ""}",
            )
            return nil
          end
        end

        if tempfile
          return upload_from_tempfile(tempfile, final_uri, url, user_id)
        end

        unless redirect_target
          Rails.logger.warn("[minicodnav] asset #{url}: redirect without Location header")
          return nil
        end

        current_url = URI.join(current_url, redirect_target).to_s
      end

      Rails.logger.warn("[minicodnav] asset #{url}: gave up after #{MAX_REDIRECTS} redirects (last hop: #{current_url})")
      nil
    rescue AssetTooBig => e
      Rails.logger.warn("[minicodnav] asset too big — #{url}: #{e.message}")
      nil
    rescue StandardError => e
      Rails.logger.warn("[minicodnav] asset pull failed — #{url}: #{e.class}: #{e.message}")
      nil
    ensure
      tempfile&.close!
    end

    def stream_to_tempfile(response, uri, max_bytes)
      cl = response.content_length
      raise AssetTooBig, "content-length #{cl} > #{max_bytes}" if cl && cl > max_bytes

      tf = Tempfile.new(["minicodnav", File.extname(uri.path).presence || ".bin"])
      tf.binmode
      total = 0

      begin
        response.read_body do |chunk|
          total += chunk.bytesize
          raise AssetTooBig, "stream exceeded #{max_bytes} bytes" if total > max_bytes
          tf.write(chunk)
        end
      rescue StandardError
        tf.close!
        raise
      end

      tf.rewind
      tf
    end

    def upload_from_tempfile(tempfile, uri, origin_url, user_id)
      basename = File.basename(uri.path)
      basename = "asset#{File.extname(uri.path)}" if basename.blank?

      owner = user_id || Discourse.system_user.id
      upload = UploadCreator.new(tempfile, basename, origin: origin_url).create_for(owner)

      unless upload&.persisted?
        errors = upload&.errors&.full_messages&.join(", ").presence || "unknown UploadCreator failure"
        Rails.logger.warn("[minicodnav] upload rejected for #{origin_url}: #{errors}")
      end
      upload
    end

    def http_for(uri)
      key = "#{uri.scheme}://#{uri.host}:#{uri.port}"
      @http_pool[key] ||=
        begin
          h = Net::HTTP.new(uri.host, uri.port)
          h.use_ssl = uri.scheme == "https"
          h.open_timeout = OPEN_TIMEOUT
          h.read_timeout = READ_TIMEOUT
          h.start
          h
        end
    end
  end
end
