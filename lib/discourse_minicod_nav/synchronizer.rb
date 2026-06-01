# frozen_string_literal: true

require "digest"

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
      fingerprint = topic_fingerprint(title, raw, tags, target_category_id)

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
          raw_sha1: fingerprint,
        )
        apply_seo!(topic, resource)
        maybe_enqueue_asset_pull(post.id, raw: raw, pdf_url: pdf_url)
        return
      end

      topic = Topic.find_by(id: map.topic_id)
      raise SyncError.new("topic not found", 422) unless topic

      # Fingerprint short-circuit: if the rendered raw + title + tags + target
      # category are byte-identical to last time we synced this resource, skip
      # the PostRevisor / DiscourseTagging path entirely. apply_seo! still runs
      # because seo can change independently; its save_custom_fields is itself
      # dirty-checked so the no-change case is cheap.
      if map.raw_sha1.present? &&
           map.raw_sha1 == fingerprint &&
           topic.category_id == target_category_id
        map.update!(last_synced_version: version, last_synced_at: Time.zone.now)
        apply_seo!(topic, resource)
        return map
      end

      if topic.category_id != target_category_id
        topic.update!(category_id: target_category_id)
      end

      first_post = topic.first_post
      raise SyncError.new("first post not found", 422) unless first_post

      # Route tags through PostRevisor so the noop-fast-path skips the (~6-10
      # query) DiscourseTagging round-trip when the set hasn't changed.
      revisor = PostRevisor.new(first_post, topic)
      revise_attrs = { raw: raw, title: title }
      revise_attrs[:tags] = tags if tags.present?
      unless revisor.revise!(@bot_user, revise_attrs, { skip_validations: true })
        raise SyncError.new(first_post.errors.full_messages.join(", "), 422)
      end

      map.update!(
        last_synced_version: version,
        last_synced_at: Time.zone.now,
        raw_sha1: fingerprint,
      )
      apply_seo!(topic, resource)
      maybe_enqueue_asset_pull(first_post.id, raw: raw, pdf_url: pdf_url)
      map
    end

    # Stable fingerprint of everything that goes into PostRevisor.revise!.
    # NUL separators avoid collisions where content happens to contain a
    # natural separator.
    def topic_fingerprint(title, raw, tags, category_id)
      Digest::SHA1.hexdigest([title, raw, Array(tags).join("\n"), category_id.to_s].join("\x00"))
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
      # save_custom_fields (no force=true) skips when nothing changed since
      # the topic was loaded; avoids 2 SELECTs + 1 redundant UPDATE on
      # idempotent webhook replays.
      topic.save_custom_fields
    end

    # Only enqueue if the rendered raw still contains upstream URLs that need
    # rehosting (or a PDF arg is set). After the first job finishes, raw no
    # longer contains base_url, so subsequent updates of the same resource (50
    # comment_count bumps from upstream, say) won't fan out 50 no-op jobs and
    # 50 redundant downloads of the same upstream PDF.
    def maybe_enqueue_asset_pull(post_id, raw:, pdf_url: nil)
      base_url = SiteSetting.minicodnav_openscholay_base_url.to_s
      return if base_url.blank?

      needs_image_pull = raw.to_s.include?(base_url)
      needs_pdf_pull = pdf_url.to_s.start_with?(base_url) && raw.to_s.include?(pdf_url.to_s)
      return unless needs_image_pull || needs_pdf_pull

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

    # Academic-paper-style layout, ordered top→bottom like a real paper page:
    #   1. Author byline with superscript-numbered affiliations + corresponding-
    #      author marker; affiliations listed below.
    #   2. Italic metadata strip (date · language · journal · issue · DOI).
    #   3. Abstract heading + paragraph.
    #   4. Keywords line.
    #   5. Journal homepage link.
    #   6. Numbered body sections (1. 评审进展, 2. 编委评分, ...). Numbering is
    #      contiguous — sections absent from the payload don't leave gaps.
    #   7. PDF section last (the inline preview is tall; pushing it to the bottom
    #      keeps the abstract above the fold).
    def build_raw_journal(resource)
      extra = resource["extra"].is_a?(Hash) ? resource["extra"] : {}
      parts = []

      author_block = render_paper_author_block(extra["author_list"])
      parts << author_block if author_block

      meta = render_journal_meta_strip(extra)
      parts << "*#{meta}*" if meta

      parts << "---" if !parts.empty?

      summary = resource["summary"].to_s
      parts << "**摘要**\n\n#{summary}" if summary.present?

      keywords = Array(extra["keywords"]).reject { |k| k.to_s.blank? }
      parts << "**关键词:** #{keywords.join(", ")}" if keywords.any?

      external = resource["external_url"].to_s
      parts << "[访问期刊主页](#{external})" if external.present?

      # Collect body sections so we can number them contiguously.
      body = []

      stage = render_review_stage_body(extra["review_stage"])
      body << ["评审进展", [stage]] if stage

      quality = render_quality_body(extra)
      body << ["编委评分", quality] if quality.any?

      notes_body = render_quality_notes_body(extra["quality_notes"])
      body << ["编委评注", [notes_body]] if notes_body

      community = render_community_body(extra)
      body << ["社区反馈", [community]] if community

      refs = render_references_body(extra["references"])
      body << ["参考文献", refs] if refs.any?

      if body.any?
        parts << "---"
        body.each_with_index do |(name, content), i|
          parts << "## #{i + 1}. #{name}"
          parts.concat(content)
        end
      end

      file_url = resource["file_url"].to_s
      if file_url.present?
        parts << "---"
        parts << "## 原文 PDF"
        parts << file_url
      end

      parts.join("\n\n")
    end

    REVIEW_STAGES = [
      { key: "latrine", emoji: "🚽", name: "旱厕(初评)" },
      { key: "septic_tank", emoji: "🪣", name: "化粪池(进阶)" },
      { key: "gou_shi", emoji: "🪨", name: "构石(精选发表)" },
    ].freeze

    DIMENSION_NAMES = {
      "ER" => "情感共鸣",
      "HP" => "钩刺指数",
      "QL" => "金句质量",
      "NA" => "叙事结构",
      "AB" => "适用受众",
      "SR" => "社会切口",
      "SAT" => "反讽密度",
      "MS" => "模因可塑性",
      "TS" => "转发安全度",
    }.freeze

    LANGUAGE_NAMES = { "zh" => "中文", "en" => "English" }.freeze

    SUPERSCRIPT_DIGITS = %w[⁰ ¹ ² ³ ⁴ ⁵ ⁶ ⁷ ⁸ ⁹].freeze

    def superscript(num)
      num.to_s.chars.map { |c| (i = c.to_i; "0123456789".include?(c) ? SUPERSCRIPT_DIGITS[i] : c) }.join
    end

    def render_paper_author_block(list)
      authors = Array(list).select { |a| a.is_a?(Hash) && a["name"].to_s.present? }
      return nil if authors.empty?

      unique_affs = []
      authors.each do |a|
        aff = a["affiliation"].to_s
        unique_affs << aff if aff.present? && !unique_affs.include?(aff)
      end
      use_superscripts = unique_affs.size > 1

      byline = authors.map do |a|
        name = a["name"].to_s
        primary = a["is_primary"] == true
        aff = a["affiliation"].to_s

        label = +"**#{name}**"
        label << superscript(unique_affs.index(aff) + 1) if use_superscripts && aff.present?
        label << "*" if primary
        label
      end.join(", ")

      parts = [byline]
      if unique_affs.size == 1
        parts << unique_affs.first
      elsif unique_affs.size > 1
        unique_affs.each_with_index { |aff, i| parts << "#{superscript(i + 1)} #{aff}" }
      end
      parts << "*\\* 通讯作者*" if authors.any? { |a| a["is_primary"] == true }

      parts.join("\n\n")
    end

    def render_journal_meta_strip(extra)
      bits = []
      bits << "发表 #{extra["published_date"]}" if extra["published_date"].to_s.present?
      lang_code = extra["language"].to_s
      bits << "语言 #{LANGUAGE_NAMES[lang_code] || lang_code}" if lang_code.present?
      platforms = Array(extra["source_platforms"]).reject { |p| p.to_s.blank? }
      bits << "期刊 #{platforms.join(", ")}" if platforms.any?
      bits << "期号 #{extra["issue_number"]}" if extra["issue_number"].to_s.present?
      bits << "DOI #{extra["doi"]}" if extra["doi"].to_s.present?
      bits.any? ? bits.join(" · ") : nil
    end

    def render_review_stage_body(stage_key)
      key = stage_key.to_s
      return nil if key.blank?

      labels = REVIEW_STAGES.map do |s|
        label = "#{s[:emoji]} #{s[:name]}"
        s[:key] == key ? "**#{label}**" : label
      end
      labels.join(" → ")
    end

    def render_quality_body(extra)
      scores = extra["quality_scores"]
      return [] unless scores.is_a?(Hash) && scores.any?

      rows = DIMENSION_NAMES.filter_map do |dim, cn|
        v = scores[dim]
        v.is_a?(Numeric) ? "| #{dim} | #{cn} | #{v} |" : nil
      end
      return [] if rows.empty?

      out = []
      overall = extra["quality_score"]
      out << "**综合评分: #{overall} / 10**" if overall.is_a?(Numeric)
      out << ["| 维度 | 名称 | 得分 |", "|---|---|---:|", *rows].join("\n")
      out
    end

    def render_quality_notes_body(notes_str)
      s = notes_str.to_s
      return nil if s.blank?
      s.lines.map { |l| "> #{l.chomp}" }.join("\n")
    end

    def render_community_body(extra)
      bits = []
      avg = extra["avg_score"]
      cnt = extra["rating_count"]
      if avg.is_a?(Numeric)
        suffix = cnt.is_a?(Numeric) ? " (#{cnt} 人参评)" : ""
        bits << "平均评分 **#{avg} / 5**#{suffix}"
      end
      comments = extra["comment_count"]
      bits << "评论数 #{comments} 条" if comments.is_a?(Numeric)
      bits.any? ? bits.join(" · ") : nil
    end

    def render_references_body(refs)
      valid = Array(refs).reject { |r| r.to_s.blank? }
      valid.each_with_index.map { |r, i| "[#{i + 1}] #{r}" }
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
