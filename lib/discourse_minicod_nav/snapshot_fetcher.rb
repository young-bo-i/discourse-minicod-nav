# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module DiscourseMinicodNav
  # Pull a full snapshot from openscholay upstream and apply each item via Synchronizer.
  # See contract v1.3 §6: cold start, disaster recovery, audit reconciliation.
  class SnapshotFetcher
    SOURCES = %w[pavlovia journal].freeze
    PAGE_LIMIT = 100
    READ_TIMEOUT = 30

    class FetchError < StandardError
    end

    def initialize(source:)
      raise ArgumentError, "invalid source: #{source}" unless SOURCES.include?(source)

      @source = source
      @base_url = SiteSetting.minicodnav_openscholay_base_url.to_s.presence
      raise FetchError, "minicodnav_openscholay_base_url not set" if @base_url.nil?

      @secret = SiteSetting.public_send("minicodnav_webhook_secret_#{source}").to_s.presence
      raise FetchError, "minicodnav_webhook_secret_#{source} not set" if @secret.nil?
    end

    def call
      synchronizer = Synchronizer.from_site_settings
      offset = 0
      applied = 0
      skipped = 0
      failed = 0

      loop do
        page = fetch_page(offset)
        data = page["data"] || {}
        items = data["items"] || []

        items.each do |evt|
          begin
            ActiveRecord::Base.transaction do
              result = synchronizer.process!(evt)
              result[:skipped] ? (skipped += 1) : (applied += 1)
            end
          rescue SyncError => e
            failed += 1
            Rails.logger.warn(
              "[minicodnav] snapshot #{@source} item failed: resource_id=#{evt.dig("resource", "id")} #{e.message}",
            )
          end
        end

        break unless data["has_more"]
        offset += data["limit"] || PAGE_LIMIT
      end

      { source: @source, applied: applied, skipped: skipped, failed: failed }
    end

    private

    def fetch_page(offset)
      uri = URI.join(@base_url, "/api/nav/snapshot/#{@source}")
      uri.query = URI.encode_www_form(offset: offset, limit: PAGE_LIMIT)

      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{@secret}"
      req["Accept"] = "application/json"

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.read_timeout = READ_TIMEOUT

      resp = http.request(req)
      unless resp.is_a?(Net::HTTPSuccess)
        raise FetchError, "snapshot #{@source} fetch failed at offset=#{offset}: #{resp.code} #{resp.message}"
      end

      JSON.parse(resp.body)
    end
  end
end
