-- ================================================================
-- V4: Indexes — performance optimization
--
-- Nguyên tắc:
-- 1. Index mọi FK column — JOIN và ON DELETE CASCADE cần nó
-- 2. Partial index cho hot path queries — nhỏ hơn, nhanh hơn
-- 3. GIN index cho JSONB và array — không dùng B-tree cho những kiểu này
-- 4. Composite index: cột có selectivity cao nhất đặt trước
-- ================================================================

-- ── USERS ──────────────────────────────────────────────────────
-- EMAIL lookup khi đăng nhập
CREATE INDEX idx_users_email
    ON users (email);

-- PHONE lookup - partial vì phone có thể NULL
CREATE UNIQUE INDEX idx_users_phone
    ON users (phone)
    WHERE phone IS NOT NULL;

-- OAuth login: tìm user theo provider + provider_id
CREATE INDEX idx_users_provider_lookup
    ON users (provider, provider_id)
    WHERE provider_id IS NOT NULL;

-- ── REFRESH TOKENS ─────────────────────────────────────────────
-- Validate token: tìm theo user, lọc chưa hết hạn và chưa revoke
-- Partial index chỉ index rows còn active -> index nhỏ, query nhanh
CREATE INDEX idx_refresh_tokens_active_lookup
    ON refresh_tokens (user_id, expires_at)
    WHERE revoked = FALSE;

-- Cleanup job: xóa token hết hạn theo batch
CREATE INDEX idx_refresh_tokens_expires_at
    ON refresh_tokens (expires_at);

-- ── USER SETTINGS ──────────────────────────────────────────────

CREATE INDEX idx_user_settings_user_id
    ON user_settings (user_id);

-- ── PERSONS ────────────────────────────────────────────────────

-- Official profile của user đang đăng nhập
-- Partial unique index — đã tạo trong V2, không cần tạo lại
-- idx_persons_one_official_per_user đã được tạo trong V2

-- Public dossier URL lookup:  /dossier/{slug}
CREATE INDEX idx_persons_slug
    ON persons (slug);

-- Load tất cả profiles (official + persona) của một user
CREATE INDEX idx_persons_user_id_type
    ON persons (user_id, profile_type);

-- Persona lookup: tìm tất cả persona của một official profile
CREATE INDEX idx_persons_parent_person_id
    ON persons (parent_person_id)
    WHERE parent_person_id IS NOT NULL;

-- GIN cho TEXT array - WHERE 'English' = ANY(languages)
CREATE INDEX idx_person_languages
    ON persons USING GIN (languages);

-- GIN cho JSONB - WHERE social_links @> '{"github":"..."}'
CREATE INDEX idx_persons_social_links
    ON persons USING GIN (social_links);

-- ── PERSON PHOTOS ──────────────────────────────────────────────

CREATE INDEX idx_person_photos_person_id
    ON person_photos (person_id, display_order);

-- Primary photo lookup — partial, chỉ 1 row per person
-- Partial unique index đã tạo trong V2
-- idx_person_photos_one_primary_per_person đã được tạo trong V2

-- ── MEDIA ITEMS ────────────────────────────────────────────────
-- Load tất cả media của một person
CREATE INDEX idx_media_item_person_id
    ON media_items (person_id);

-- Filter theo loại media: "Chỉ hiện phim"
CREATE INDEX idx_media_item_person_type
    ON media_items (person_id, media_type);

-- Filter theo status: "Danh sách phim muốn xem"
CREATE INDEX idx_media_items_person_status
    ON media_items (person_id, status);

-- Hot patch của Intelligence Engine: chỉ COMPLETED items mới được SCORE
-- Partial index -> bỏ qua WANT_TO, IN_PROGRESS, DROPPED hoàn toàn
CREATE INDEX idx_media_items_completed_for_scoring
    ON media_items (person_id, consumed_at DESC)
    WHERE status = 'COMPLETED';

-- GIN cho JSONB metadata - tìm theo genre, author, etc.
CREATE INDEX idx_media_items_metadata
    ON media_items USING GIN (metadata);

-- ── TAGS ───────────────────────────────────────────────────────
CREATE INDEX idx_tags_person_id
    ON tags (person_id);

-- Junction table: reversed lookup - "media nào có tag này?"
CREATE INDEX idx_media_item_tags_tag_id
    ON media_item_tags (tag_id);

-- ── RELATIONSHIPS ──────────────────────────────────────────────
CREATE INDEX idx_relationships_person_id
    ON relationships (person_id);

-- Graph metrics chỉ dùng quan hệ đang active
-- Partial index bỏ qua các quan hệ đã ended_at
CREATE INDEX idx_relationships_active_graph
    ON relationships (person_id, relationship_type, strength)
    WHERE ended_at IS NULL;

-- Tìm kiếm contact theo email - người dùng có thể search
CREATE INDEX idx_relationships_related_email
    ON relationships (related_email)
    WHERE related_email IS NOT NULL;

-- Lookup ngược: ai đang link đến person này?
CREATE INDEX idx_relationships_linked_person_id
    ON relationships (linked_person_id)
    WHERE linked_person_id IS NOT NULL;

-- ── TIMELINE EVENTS ────────────────────────────────────────────
-- Load và sort theo thời gian - DESC vì UI hiện mới nhất trước
CREATE INDEX idx_timeline_events_person_date
    ON timeline_events (person_id, event_date DESC);

-- Milestones query riêng để render nổi bật trên UI
CREATE INDEX idx_timeline_events_milestones
    ON timeline_events (person_id)
    WHERE is_milestone = TRUE;

-- ── EVENT PHOTOS ───────────────────────────────────────────────

CREATE INDEX idx_event_photos_event_id
    ON event_photos (event_id, display_order);

-- ── DOSSIER SHARES ─────────────────────────────────────────────
-- Public URL: GET /dossier/{slug}
CREATE INDEX idx_dossier_shares_slug
    ON dossier_shares (slug);

-- Cleanup job: vô hiệu hóa link hết hạn
-- Partial index chỉ include rows có set expires_at
CREATE INDEX idx_dossier_shares_expires_at
    ON dossier_shares (expires_at)
    WHERE expires_at IS NOT NULL;

-- ── INTELLIGENCE ───────────────────────────────────────────────
CREATE INDEX idx_person_scores_person_id
    ON person_scores (person_id);

-- Load insights để hiển thị: chỉ active insights
CREATE INDEX idx_person_insights_active
    ON person_insights (person_id, insight_type)
    WHERE is_active = TRUE;

-- ── CACHE INVALIDATION ─────────────────────────────────────────
-- Tìm entities thay đổi sau một timestamp - dùng cho sync/cache
CREATE INDEX idx_person_updated_at
    ON persons (updated_at DESC);

CREATE INDEX idx_media_items_updated_at
    ON media_items (updated_at DESC);

-- ── INTELLIGENCE STALENESS CHECK ───────────────────────────────
-- So sánh computed_at với media_items.updated_at để quyết định recompute
CREATE INDEX idx_person_scores_computed_at
    ON person_scores (computed_at);

-- ── TIMELINE FILTERING ─────────────────────────────────────────
CREATE INDEX idx_timeline_events_person_type
    ON timeline_events (person_id, event_type);

-- ── INSIGHTS CLEANUP ───────────────────────────────────────────
CREATE INDEX idx_person_insights_expires_at
    ON person_insights (expires_at)
    WHERE expires_at IS NOT NULL;