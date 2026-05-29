# frozen_string_literal: true

module DiscourseMinicodNav
  class SyncError < StandardError
    attr_reader :status

    def initialize(message, status = 400)
      super(message)
      @status = status
    end
  end

  # Applies Resource Station webhook payload (contract v1.3: 4 resource events).
  class Synchronizer
    EVENT_CREATED = "resource.created"
    EVENT_UPDATED = "resource.updated"
    EVENT_ARCHIVED = "resource.archived"
    EVENT_DELETED = "resource.deleted"

    def initialize(bot_user:)
      @bot_user = bot_user
    end

    def self.from_site_settings
      new(bot_user: Discourse.system_user)
    end

    def process!(payload)
      event = payload["event"].to_s
      version = payload["version"].to_i

      resource = payload["resource"]
      raise SyncError.new("resource missing", 400) unless resource.is_a?(Hash)

      resource_id = resource["id"].to_s
      raise SyncError.new("resource.id missing", 400) if resource_id.blank?

      map = ResourceMap.find_by(resource_id: resource_id) || adopt_existing_topic(resource_id, resource)

      if map && version.positive? && version < map.last_synced_version
        return { skipped: true, reason: "older_version" }
      end

      case event
      when EVENT_CREATED, EVENT_UPDATED
        upsert_topic!(resource, map, version)
      when EVENT_ARCHIVED
        archive_topic!(map, version)
      when EVENT_DELETED
        delete_topic!(map, version)
      else
        raise SyncError.new("unsupported event: #{event}", 400)
      end

      { ok: true }
    end

    private

    def guardian
      @guardian ||= Guardian.new(@bot_user)
    end

    # Contract §4: if upstream knows we synced this resource before (e.g. plugin DB was wiped
    # but Discourse topic still exists), it sends discourse_topic_id. Re-bind our map to that
    # topic instead of creating a duplicate.
    def adopt_existing_topic(resource_id, resource)
      topic_id = resource["discourse_topic_id"].to_i
      return nil if topic_id <= 0

      topic = Topic.find_by(id: topic_id)
      return nil if topic.nil?

      first_post = topic.first_post
      return nil if first_post.nil?

      ResourceMap.create!(
        resource_id: resource_id,
        topic_id: topic.id,
        post_id: first_post.id,
        last_synced_version: 0,
        last_synced_at: Time.zone.now,
      )
    end

    # Prefer payload discourse_category_id; otherwise route by source_type to its configured category.
    def discourse_category_id_for(resource)
      payload_cid = resource["discourse_category_id"].to_i
      return payload_cid if payload_cid.positive?

      case resource["source_type"].to_s
      when "pavlovia"
        cid = SiteSetting.minicodnav_pavlovia_category_id.to_i
        raise SyncError.new("minicodnav_pavlovia_category_id not set", 503) if cid <= 0
        cid
      when "journal"
        cid = SiteSetting.minicodnav_journal_category_id.to_i
        raise SyncError.new("minicodnav_journal_category_id not set", 503) if cid <= 0
        cid
      else
        raise SyncError.new("unsupported source_type: #{resource["source_type"]}", 400)
      end
    end

    def upsert_topic!(resource, map, version)
      title = resource["title"].to_s
      raise SyncError.new("title required", 422) if title.blank?

      raw = build_raw(resource)
      pdf_url = resource["file_url"].to_s.presence

      tags = normalize_tags(Array(resource["tags"]))
      target_category_id = discourse_category_id_for(resource)

      if map.nil?
        create_opts = {
          title: title,
          raw: raw,
          category: target_category_id,
          skip_validations: true,
          import_mode: true,
        }
        create_opts[:tags] = tags if tags.present?

        post = PostCreator.create!(@bot_user, create_opts)
        topic = post.topic
        ResourceMap.create!(
          resource_id: resource["id"].to_s,
          topic_id: topic.id,
          post_id: post.id,
          last_synced_version: version,
          last_synced_at: Time.zone.now,
        )
        apply_seo!(topic, resource)
        enqueue_asset_pull(post.id, pdf_url: pdf_url)
        return
      end

      topic = Topic.find_by(id: map.topic_id)
      raise SyncError.new("topic not found", 422) unless topic

      if topic.category_id != target_category_id
        topic.update!(category_id: target_category_id)
      end

      first_post = topic.first_post
      raise SyncError.new("first post not found", 422) unless first_post

      revisor = PostRevisor.new(first_post, topic)
      unless revisor.revise!(@bot_user, { raw: raw, title: title }, { skip_validations: true })
        raise SyncError.new(first_post.errors.full_messages.join(", "), 422)
      end

      if tags.present?
        tag_ok = DiscourseTagging.tag_topic_by_names(topic, guardian, tags)
        raise SyncError.new(topic.errors.full_messages.join(", "), 422) unless tag_ok
      end

      map.update!(last_synced_version: version, last_synced_at: Time.zone.now)
      apply_seo!(topic, resource)
      enqueue_asset_pull(first_post.id, pdf_url: pdf_url)
      map
    end

    # Contract v1.6 §4.6: write upstream-curated SEO into topic custom fields
    # so plugin.rb's html_builder hook can emit them as <meta> tags.
    def apply_seo!(topic, resource)
      seo = resource["seo"]
      return unless seo.is_a?(Hash)

      cf = topic.custom_fields
      cf["minicodnav_meta_description"] = seo["description"].to_s if seo["description"].to_s.present?
      cf["minicodnav_og_title"] = seo["title"].to_s if seo["title"].to_s.present?
      cf["minicodnav_og_image"] = seo["og_image"].to_s if seo["og_image"].to_s.present?
      keywords = Array(seo["keywords"]).reject { |k| k.to_s.blank? }
      cf["minicodnav_meta_keywords"] = keywords.join(", ") if keywords.any?
      topic.save_custom_fields(true)
    end

    def enqueue_asset_pull(post_id, pdf_url: nil)
      Jobs.enqueue(:minicod_nav_pull_assets, post_id: post_id, pdf_url: pdf_url)
    end

    # Contract v1.4 §3.2 allows building the post body from structured fields.
    # v1.7/v1.8: journal payloads no longer ship a ready-to-use markdown content
    # block; that data is now spread across extra.* fields, so journal posts
    # render from structured fields. Pavlovia still has a clean content field.
    def build_raw(resource)
      case resource["source_type"].to_s
      when "journal"
        build_raw_journal(resource)
      else
        build_raw_default(resource)
      end
    end

    def build_raw_default(resource)
      source = resource["source_type"].to_s
      parts = []

      summary = resource["summary"].to_s
      parts << "**简介:** #{summary}" if summary.present?

      file_url = resource["file_url"].to_s
      if file_url.present?
        parts << "## 📄 原文 PDF"
        parts << file_url
      end

      external = resource["external_url"].to_s
      parts << "[#{external_link_text(source)}](#{external})" if external.present?

      content = resource["content"].to_s
      if content.present?
        parts << "## 详细介绍"
        parts << content
      end

      parts.join("\n\n")
    end

    # Journal body composed from extra.* (contract v1.7 §4.4).
    def build_raw_journal(resource)
      extra = resource["extra"].is_a?(Hash) ? resource["extra"] : {}
      parts = []

      summary = resource["summary"].to_s
      parts << "**简介:** #{summary}" if summary.present?

      file_url = resource["file_url"].to_s
      if file_url.present?
        parts << "## 📄 原文 PDF"
        parts << file_url
      end

      external = resource["external_url"].to_s
      parts << "[访问期刊主页](#{external})" if external.present?

      author_block = render_authors(extra["author_list"])
      parts.concat(author_block) if author_block.any?

      notes = extra["quality_notes"].to_s
      if notes.present?
        parts << "## 编委评注"
        parts << notes.lines.map { |l| "> #{l.chomp}" }.join("\n")
      end

      score_block = render_quality_scores(extra["quality_scores"])
      parts.concat(score_block) if score_block.any?

      refs = Array(extra["references"]).reject { |r| r.to_s.blank? }
      if refs.any?
        parts << "## 参考文献"
        refs.each_with_index { |r, i| parts << "#{i + 1}. #{r}" }
      end

      parts.join("\n\n")
    end

    def render_authors(list)
      authors = Array(list).select { |a| a.is_a?(Hash) }
      return [] if authors.empty?

      lines = ["## 作者"]
      authors.each do |a|
        name = a["name"].to_s
        next if name.blank?

        affiliation = a["affiliation"].to_s
        bio = a["bio"].to_s
        primary = a["is_primary"] == true

        header = primary ? "**#{name}** (通讯)" : "**#{name}**"
        header += " — *#{affiliation}*" if affiliation.present?
        lines << "- #{header}"
        lines << "  > #{bio}" if bio.present?
      end
      lines.size > 1 ? [lines.join("\n")] : []
    end

    QUALITY_DIMENSIONS = %w[ER HP QL NA AB SR SAT MS TS].freeze

    def render_quality_scores(scores)
      return [] unless scores.is_a?(Hash) && scores.any?

      rows = QUALITY_DIMENSIONS.filter_map do |dim|
        v = scores[dim]
        v.is_a?(Numeric) ? "| #{dim} | #{v} |" : nil
      end
      return [] if rows.empty?

      table = ["| 维度 | 得分 |", "|---|---:|", *rows].join("\n")
      ["## SHIT 9 维评分", table]
    end

    def external_link_text(source)
      case source
      when "pavlovia"
        "前往 Pavlovia 运行实验"
      when "journal"
        "访问期刊主页"
      else
        "查看原始页面"
      end
    end

    def archive_topic!(map, version)
      # Never synced to Discourse — treat as idempotent success (Outbox may replay
      # archive/delete before a create, or resource was only local).
      return if map.nil?

      topic = Topic.find_by(id: map.topic_id)
      raise SyncError.new("topic not found", 422) unless topic

      topic.update_status(:closed, true, @bot_user)
      map.update!(last_synced_version: version, last_synced_at: Time.zone.now)
    end

    def delete_topic!(map, version)
      return if map.nil?

      topic = Topic.unscoped.find_by(id: map.topic_id)
      raise SyncError.new("topic not found", 422) unless topic

      if topic.deleted_at.blank?
        first_post = topic.first_post
        raise SyncError.new("first post not found", 422) unless first_post

        PostDestroyer.new(@bot_user, first_post).destroy
      end

      map.update!(last_synced_version: version, last_synced_at: Time.zone.now)
    end

    def normalize_tags(tags)
      max = SiteSetting.max_tags_per_topic.to_i
      max = 5 if max <= 0
      tags.map(&:to_s).map(&:strip).reject(&:blank?).uniq.take(max)
    end
  end
end
