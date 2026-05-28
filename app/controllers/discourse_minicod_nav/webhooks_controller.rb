# frozen_string_literal: true

require "openssl"

module DiscourseMinicodNav
  # Inherit ActionController::Base like core Discourse::WebhooksController — not ApplicationController,
  # which runs many before_actions (theme, locale, login, xhr, layout preload) that break
  # anonymous server-to-server POSTs and surface as generic JSON 500.
  class WebhooksController < ActionController::Base
    layout false

    include ReadOnlyMixin

    skip_before_action :verify_authenticity_token, raise: false

    before_action :check_readonly_mode
    before_action :block_if_readonly_mode

    rescue_from Discourse::ReadOnly do
      head :service_unavailable
    end

    def create
      unless SiteSetting.minicodnav_plugin_enabled
        return render json: { error: "plugin disabled", code: "minicodnav_plugin_disabled" }, status: 403
      end

      secret = SiteSetting.minicodnav_webhook_secret.to_s
      if secret.blank?
        return render json: { error: "minicodnav_webhook_secret not set" }, status: 503
      end

      raw = request.body.read

      unless verify_signature!(raw, secret)
        return render json: { error: "invalid signature" }, status: 401
      end

      unless fresh_timestamp?
        return render json: { error: "stale timestamp" }, status: 401
      end

      payload = JSON.parse(raw)
      delivery_id = request.headers["X-AcadNav-Delivery"].presence
      return render json: { error: "missing X-AcadNav-Delivery" }, status: 401 if delivery_id.blank?
      event = payload["event"].to_s
      resource_id = payload.dig("resource", "id").to_s
      start_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      begin
        ActiveRecord::Base.transaction do
          result = DiscourseMinicodNav::Synchronizer.from_site_settings.process!(payload)
          elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_at) * 1000).to_i
          WebhookReceipt.create!(
            delivery_id: delivery_id,
            event: event,
            resource_id: resource_id.presence,
            status: result[:skipped] ? "skipped" : "ok",
            duration_ms: elapsed_ms,
            created_at: Time.zone.now,
          )
        end
      rescue ActiveRecord::RecordNotUnique
        return render json: { ok: true, deduped: true }, status: 200
      end

      render json: { ok: true }, status: 200
    rescue JSON::ParserError
      render json: { error: "invalid json" }, status: 400
    rescue DiscourseMinicodNav::SyncError => e
      Rails.logger.warn("[minicodnav] sync error: #{e.message}")
      render json: { error: e.message }, status: e.status
    rescue StandardError => e
      Rails.logger.error("[minicodnav] #{e.class}: #{e.message}\n#{e.backtrace&.first(12)&.join("\n")}")
      render json: { error: "internal error", exception: e.class.name, message: e.message }, status: 500
    end

    private

    def verify_signature!(raw, secret)
      sig_header = request.headers["X-AcadNav-Signature"].to_s
      sig = sig_header.delete_prefix("sha256=").strip
      expected = OpenSSL::HMAC.hexdigest("SHA256", secret, raw)
      return false if expected.bytesize != sig.bytesize

      ActiveSupport::SecurityUtils.secure_compare(expected, sig)
    end

    def fresh_timestamp?
      ts = request.headers["X-AcadNav-Timestamp"].to_s.to_i
      return false if ts <= 0

      (Time.zone.now.to_i - ts).abs <= 300
    end
  end
end
