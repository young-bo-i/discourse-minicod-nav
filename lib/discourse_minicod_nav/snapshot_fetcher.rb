# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module DiscourseMinicodNav
  # Pull a full snapshot from openscholay upstream and apply each item via Synchronizer.
  # See contract v1.3 §6: cold start, disaster recovery, audit reconciliation.
  #
  # Two entry points:
  #   - SnapshotFetcher#run!(snapshot_run) — drives an existing SnapshotRow,
  #     checkpointing progress per page so a SIGTERM / crash mid-loop loses at
  #     most one page of work. Used by Jobs::MinicodNavRunSnapshot.
  #   - SnapshotFetcher#call — creates a one-off SnapshotRow and runs to
  #     completion inline (for the bin/rails runner script).
  class SnapshotFetcher
    SOURCES = %w[pavlovia journal].freeze
    PAGE_LIMIT = 100
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30
    MAX_RESPONSE_BYTES = 50 * 1024 * 1024

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

    # Drives a SnapshotRun: each page advances next_offset and accumulates
    # counters atomically, so a retry can pick up exactly where we left off.
    def run!(snapshot_run)
      synchronizer = Synchronizer.from_site_settings
      http = build_http

      begin
        loop do
          page = fetch_page(http, snapshot_run.next_offset)
          data = page["data"] || {}
          items = data["items"] || []

          new_applied = 0
          new_skipped = 0
          new_failed = 0

          # Batch short-circuit: one indexed SELECT per page replaces the per-item
          # ResourceMap.find_by + transaction overhead that Synchronizer.process!
          # would do for items already at our version (the common case on
          # repeated snapshot reconciliation).
          known_versions = fetch_known_versions(items)

          items.each do |evt|
            resource_id = evt.dig("resource", "id").to_s
            event_version = evt["version"].to_i

            if event_version.positive? && (known = known_versions[resource_id]) && event_version <= known
              new_skipped += 1
              next
            end

            begin
              ActiveRecord::Base.transaction do
                result = synchronizer.process!(evt)
                result[:skipped] ? (new_skipped += 1) : (new_applied += 1)
              end
            rescue SyncError => e
              new_failed += 1
              Rails.logger.warn(
                "[minicodnav] snapshot #{@source} item failed: " \
                  "resource_id=#{resource_id} #{e.message}",
              )
            end
          end

          snapshot_run.update!(
            applied: snapshot_run.applied + new_applied,
            skipped: snapshot_run.skipped + new_skipped,
            failed: snapshot_run.failed + new_failed,
            next_offset: snapshot_run.next_offset + items.size,
            total_items: snapshot_run.total_items || data["total"]&.to_i,
          )

          break unless data["has_more"]
        end
      ensure
        begin
          http.finish
        rescue StandardError
          nil
        end
      end

      snapshot_run
    end

    def fetch_known_versions(items)
      ids = items.filter_map { |evt| evt.dig("resource", "id").to_s.presence }.uniq
      return {} if ids.empty?

      ResourceMap.where(resource_id: ids).pluck(:resource_id, :last_synced_version).to_h
    end

    def call
      run = SnapshotRun.create!(source: @source, status: "running", started_at: Time.zone.now)
      run!(run)
      run.update!(status: "completed", finished_at: Time.zone.now)
      {
        source: @source,
        applied: run.applied,
        skipped: run.skipped,
        failed: run.failed,
      }
    end

    private

    def build_http
      uri = URI.parse(@base_url)
      h = Net::HTTP.new(uri.host, uri.port)
      h.use_ssl = uri.scheme == "https"
      h.open_timeout = OPEN_TIMEOUT
      h.read_timeout = READ_TIMEOUT
      h.start
      h
    end

    def fetch_page(http, offset)
      path = "/api/nav/snapshot/#{@source}?#{URI.encode_www_form(offset: offset, limit: PAGE_LIMIT)}"
      req = Net::HTTP::Get.new(path)
      req["Authorization"] = "Bearer #{@secret}"
      req["Accept"] = "application/json"

      resp = http.request(req)
      unless resp.is_a?(Net::HTTPSuccess)
        raise FetchError, "snapshot #{@source} fetch failed at offset=#{offset}: #{resp.code} #{resp.message}"
      end

      body = resp.body.to_s
      if body.bytesize > MAX_RESPONSE_BYTES
        raise FetchError, "snapshot page too large at offset=#{offset}: #{body.bytesize} bytes > #{MAX_RESPONSE_BYTES}"
      end

      JSON.parse(body)
    end
  end
end
