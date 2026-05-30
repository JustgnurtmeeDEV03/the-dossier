-- ================================================================
-- V2: Profile tables — nội dung "hồ sơ mật"
-- persons         : dossier profile — OFFICIAL hoặc PERSONA
-- person_photos   : gallery ảnh đính kèm profile
-- media_items     : phim/sách/nhạc với JSONB metadata
-- tags            : nhãn phân loại media
-- media_item_tags : junction M:N giữa media và tag
-- relationships   : mạng quan hệ xã hội, tuỳ chọn link platform user
-- timeline_events : sự kiện cuộc đời với ảnh đính kèm
-- event_photos    : gallery ảnh cho từng sự kiện
-- dossier_shares  : cài đặt chia sẻ public từng section
-- ================================================================

CREATE TABLE persons
(
    id                  UUID                NOT NULL DEFAULT gen_random_uuid(),
    user_id             UUID                NOT NULL,
    display_name        VARCHAR(100)        NOT NULL,
    bio                 TEXT,
    slug                VARCHAR(100)        NOT NULL, -- URL: /dossier/{slug}
    avatar_url          VARCHAR(500),

    -- Thông tin cấ nhân cơ bản
    birth_date          DATE,
    gender              VARCHAR(30),
    nationality         VARCHAR(100),
    hometown            VARCHAR(200),
    current_location    VARCHAR(200),
    occupation          VARCHAR(200),
    education           VARCHAR(200),
    -- height_cm: đơn vị cm, SMALLINT đủ cho 0-32767
    height_cm           SMALLINT,
    -- weight_kg: cho phép thập phân, ví dụ 65.50kg
    weight_kg           DECIMAL(5, 2),
    languages           TEXT[]              NOT NULL DEFAULT '{}',
    social_links        JSONB               NOT NULL DEFAULT '{}',
    life_motto          VARCHAR(300),       -- Phương châm sống - "Work hard, stay humble"
    favorite_quote      VARCHAR(500),       -- Câu trích dẫn yêu thích kèm tác giả

    -- Persona system
    -- OFFICIAL: Hồ sơ chính thức, 1 per user
    -- PERSONA:  Hồ sơ nhân vật phụ, liên kết ẩn về OFFICIAL
    profile_type        VARCHAR(20)         NOT NULL DEFAULT 'OFFICIAL',
    -- NULL CHO OFFICIAL , trỏ về persons.id OFFICIAL cho PERSONA
    -- Hidden link - không bao giờ expose qua public API
    parent_person_id    UUID,

    created_at          TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_persons
        PRIMARY KEY (id),

    -- Slug unique toàn hệ thống - dùng cho public URL
    CONSTRAINT persons_slug_unique
        UNIQUE (slug),

    -- Slug chỉ gồm chữ thường, số, dấu gạch ngang - URL safe
    CONSTRAINT persons_slug_format
        CHECK (slug ~ '^[a-z0-9-]+$'),

    CONSTRAINT persons_profile_type_check
        CHECK (profile_type IN ('OFFICIAL', 'PERSONA')),

    CONSTRAINT persons_gender_check
        CHECK (gender IN ('MALE', 'FEMALE', 'OTHER', 'PREFER_NOT_TO_SAY')),

    CONSTRAINT persons_height_positive
        CHECK (height_cm IS NULL OR height_cm > 0),

    CONSTRAINT persons_weight_positive
        CHECK (weight_kg IS NULL OR weight_kg > 0),

    -- Đảm bảo tính nhất quán persona/official:
    -- OFFICIAL không có parent, PERSONA bắt buộc phải có parent
    CONSTRAINT persons_persona_consitency
        CHECK (
            (profile_type = 'OFFICIAL' AND parent_person_id IS NULL) OR
            (profile_type = 'PERSONA' AND parent_person_id IS NOT NULL)
        ),

    CONSTRAINT fk_persons_user
        FOREIGN KEY (user_id)
            REFERENCES users (id)
            ON DELETE CASCADE,

    -- Self-referential FK: persona -> official profile
    -- CASCADE: Xóa official -> xóa hết persona liên quan
    CONSTRAINT fk_persons_parent
        FOREIGN KEY (parent_person_id)
            REFERENCES persons (id)
            ON DELETE CASCADE
);


CREATE TRIGGER trg_persons_updated_at
    BEFORE UPDATE ON persons
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Partial unique index thay cho table-level UNIQUE:
-- Cho phép 1 user có nhiều PERSONA nhưng chỉ 1 OFFICIAL
-- Giới hạn tối đa 2 persona được enforce ở application layer
CREATE UNIQUE INDEX idx_persons_one_official_per_user
       ON persons (user_id)
       WHERE profile_type = 'OFFICIAL';

COMMENT ON TABLE persons
    IS 'Dossier profiles — one OFFICIAL per user, up to 2 PERSONA (app-enforced)';
COMMENT ON COLUMN persons.avatar_url
    IS 'Dossier avatar — separate from users.avatar_url which is OAuth provider photo';
COMMENT ON COLUMN persons.height_cm
    IS 'Height in centimeters — SMALLINT sufficient (max 32767)';
COMMENT ON COLUMN persons.weight_kg
    IS 'Weight in kg — DECIMAL(5,2) allows e.g. 65.50';
COMMENT ON COLUMN persons.profile_type
    IS 'OFFICIAL=main verified identity | PERSONA=alternate identity linked to OFFICIAL';
COMMENT ON COLUMN persons.parent_person_id
    IS 'Hidden link for PERSONA profiles — never returned in public API responses';
COMMENT ON COLUMN persons.languages
    IS 'PostgreSQL TEXT array, e.g. {Vietnamese,English,Japanese}';
COMMENT ON COLUMN persons.social_links
    IS 'JSONB: {"github":"...","linkedin":"...","twitter":"..."}';
COMMENT ON COLUMN persons.life_motto
    IS 'Personal motto or mantra — short phrase that defines how they live';
COMMENT ON COLUMN persons.favorite_quote
    IS 'Favorite quote, ideally with attribution: "Quote text — Author Name"';

-- ----------------------------------------------------------------

CREATE TABLE person_photos
(
    id              UUID                NOT NULL DEFAULT gen_random_uuid(),
    person_id       UUID                NOT NULL,
    photo_url       VARCHAR(500)        NOT NULL,
    caption         VARCHAR(200),
    display_order   SMALLINT            NOT NULL DEFAULT 0,
    -- Chỉ 1 ảnh được đánh dấu primary per person (enforced bởi partial unique index)
    is_primary      BOOLEAN             NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_person_photos
        PRIMARY KEY (id),

    CONSTRAINT fk_person_photos_person
        FOREIGN KEY (person_id)
            REFERENCES persons (id)
            ON DELETE CASCADE
);

-- Đảm bảo mỗi person chỉ có đúng 1 ảnh primary
CREATE UNIQUE INDEX idx_person_photos_one_primary_per_person
    ON person_photos (person_id)
    WHERE is_primary = TRUE;

COMMENT ON TABLE person_photos
    IS 'Profile gallery — multiple photos per person, one marked as primary';

-- ----------------------------------------------------------------

CREATE TABLE media_items
(
    id              UUID                NOT NULL DEFAULT gen_random_uuid(),
    person_id       UUID                NOT NULL,
    media_type      VARCHAR(20)         NOT NULL,
    external_id     VARCHAR(255)        NOT NULL,  -- ID từ TMDB / Google Books / Spotify
    source          VARCHAR(20)         NOT NULL DEFAULT 'MANUAL',
    title           VARCHAR(500)        NOT NULL,
    cover_url       VARCHAR(500),        -- cache ảnh bìa, tránh gọi lại external API
    rating          SMALLINT,            -- 1-10
    status          VARCHAR(20)         NOT NULL DEFAULT    'COMPLETED',
    consumed_at     DATE,               -- ngày hoàn thành xem/đọc/nghe
    notes           TEXT,
    metadata        JSONB               NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_media_items
        PRIMARY KEY (id),

    CONSTRAINT fk_media_items_person
        FOREIGN KEY (person_id)
            REFERENCES persons (id)
            ON DELETE CASCADE,

    CONSTRAINT media_items_type_check
        CHECK ( media_type IN ('MOVIE', 'BOOK', 'MUSIC_TRACK', 'MUSIC ALBUM')),

    CONSTRAINT media_items_source_check
        CHECK (source IN ('TMDB', 'GOOGLE_BOOKS', 'SPOTIFY', 'MANUAL')),

    CONSTRAINT media_items_status_check
        CHECK ( status IN ('WANT_TO', 'IN_PROGRESS', 'COMPLETED', 'DROPPED')),

    CONSTRAINT media_items_rating_range
        CHECK ( rating BETWEEN 1 AND 10),

    -- Một người không thể lưu trùng cùng một item từ cùng nguồn
    CONSTRAINT media_items_person_external_unique
        UNIQUE (person_id, media_type, external_id)
);

CREATE TRIGGER trg_media_items_updated_at
    BEFORE UPDATE ON media_items
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE media_items
    IS 'Movies, books, music saved to a dossier — sourced from external APIs';
COMMENT ON COLUMN media_items.external_id
    IS 'Source API ID: TMDB movie id | Google Books volumeId | Spotify track/album id';
COMMENT ON COLUMN media_items.source
    IS 'Which API to call for metadata refresh: TMDB | GOOGLE_BOOKS | SPOTIFY | MANUAL=no refresh';
COMMENT ON COLUMN media_items.cover_url
    IS 'Cached to avoid re-fetching from external API on every page load';
COMMENT ON COLUMN media_items.status
    IS 'Scoring weights: WANT_TO=0.3 | IN_PROGRESS=0.7 | COMPLETED=1.0 | DROPPED=0.1';
COMMENT ON COLUMN media_items.metadata
    IS 'Flexible fields per type: {genres, release_year} | {authors, pages} | {artists, duration}';

-- ----------------------------------------------------------------

CREATE TABLE tags
(
    id              UUID                NOT NULL DEFAULT gen_random_uuid(),
    person_id       UUID                NOT NULL,
    name            VARCHAR(50)         NOT NULL,
    color           VARCHAR(7)          NOT NULL DEFAULT '#6366f1',
    description     VARCHAR(200),
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_tags
        PRIMARY KEY (id),

    CONSTRAINT fk_tags_person
        FOREIGN KEY (person_id)
            REFERENCES persons (id)
            ON DELETE CASCADE,

    -- Cùng một người không thể có 2 tag trùng tên
    CONSTRAINT tags_person_name_unique
        UNIQUE (person_id, name),

    -- Validate đúng định dạng hex color
    CONSTRAINT tags_color_hext_format
        CHECK (color ~ '^#[0-9A-Fa-f]{6}$')
);

COMMENT ON TABLE tags
    IS 'User-defined labels for categorizing media items';
COMMENT ON COLUMN tags.color
    IS 'Hex color code validated by CHECK constraint, e.g. #6366f1';

-- ----------------------------------------------------------------

CREATE TABLE person_interests
(
    id              UUID                NOT NULL DEFAULT gen_random_uuid(),
    person_id       UUID                NOT NULL,
    -- Tên sở thích do người dùng tự nhập
    -- Ví dụ: "Guitar fingerstyle", "Leo núi", "Nhiếp ảnh phim"
    name            VARCHAR(100)        NOT NULL,
    category        VARCHAR(30)         NOT NULL,
    -- 1=casual (thỉnh thoảng) -> 5=passionate (đam mê cháy bỏng)
    passion_level   SMALLINT            NOT NULL DEFAULT 3,
    -- Mô tả chi tiết - "Chơi từ 2018, chủ yếu nhạc acoustic fingerstyle"
    description     TEXT,
    -- Năm bắt đầu có sở thích này - dùng SMALLINT vì chỉ cần 4 chữ số
    since_year      SMALLINT,
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_person_interests
        PRIMARY KEY (id),

    CONSTRAINT fk_person_interests_person
        FOREIGN KEY (person_id)
            REFERENCES persons (id)
            ON DELETE CASCADE ,

    CONSTRAINT person_interests_category_check
        CHECK (category IN (
            'SPORTS',   -- thể thao
            'ARTS',     -- hội họa, điêu khắc, thiết kế
            'MUSIC',    -- nhạc cụ, nghe nhạc, sản xuất nhạc
            'READING',  -- đọc sách, truyện, báo
            'GAMING',   -- game điện tử, board game
            'TECH',     -- lập trình, hardware, AI
            'COOKING',  -- nấu ăn, pha chế
            'FITNESS',  -- gym, yoga, chạy bộ
            'TRAVEL',   -- du lịch, khám phá
            'NATURE',   -- leo núi, cắm trại, nhiếp ảnh thiên nhiên
            'WRITING',  -- viết lách, blog, thơ
            'FILM',     -- xem phim, làm phim
            'OTHER'
        )),

    CONSTRAINT person_interests_passion_range
        CHECK (passion_level BETWEEN 1 AND 5),

    CONSTRAINT person_interests_since_year_range
        CHECK (since_year IS NULL OR (since_year >= 1900 AND since_year <= EXTRACT(YEAR FROM NOW()))),

    -- Một người không thể có 2 s thích trùng tên
    CONSTRAINT person_interests_person_name_unique
        UNIQUE (person_id, name)
);

CREATE TRIGGER trg_person_interests_updated_at
    BEFORE UPDATE ON person_interests
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE person_interests
    IS 'Hobbies and passions — self-reported, used by Intelligence Engine for personality profiling';
COMMENT ON COLUMN person_interests.name
    IS 'Free-text hobby name entered by user, e.g. "Guitar fingerstyle", "Street photography"';
COMMENT ON COLUMN person_interests.passion_level
    IS '1=casual to 5=deeply passionate — weights interest contribution to personality scores';
COMMENT ON COLUMN person_interests.since_year
    IS 'Year they started this hobby — enables timeline correlation with life events';

-- ----------------------------------------------------------------

CREATE TABLE media_item_tags
(
    media_item_id               UUID NOT NULL,
    tag_id                      UUID NOT NULL,

    CONSTRAINT pk_media_item_tags
        PRIMARY KEY (media_item_id, tag_id),

    CONSTRAINT fk_mit_media_item
        FOREIGN KEY (media_item_id)
            REFERENCES media_items (id)
            ON DELETE CASCADE,

    CONSTRAINT fk_mit_tag
        FOREIGN KEY (tag_id)
            REFERENCES tags (id)
            ON DELETE CASCADE
);

COMMENT ON TABLE media_item_tags
    IS 'Junction table for M:N between media_items and tags';

-- ----------------------------------------------------------------

CREATE TABLE relationships
(
    id                  UUID                NOT NULL DEFAULT gen_random_uuid(),
    person_id           UUID                NOT NULL,

    -- ── Tầng 1: Thông tin cá nhân của người trong quan hệ ──────
    -- Người dùng tự nhập — không bắt buộc phải có tài khoản platform
    related_name        VARCHAR(100)        NOT NULL,
    related_avatar_url  VARCHAR(500),
    related_birth_date  DATE,
    related_gender      VARCHAR(30),
    related_occupation  VARCHAR(200),
    related_location    VARCHAR(200),
    related_email       VARCHAR(255),
    related_phone       VARCHAR(20),
    related_social_links JSONB NOT NULL DEFAULT '{}',
    -- Mô tả về con người họ theo góc nhìn của người dùng
    -- Ví dụ: "người bạn thân nhất hồi cấp 3, hướng nội, rất đáng tin"
    related_bio         TEXT,

    -- ── Platform link ──────────────────────────────────────────
    -- Chỉ set khi người này CÓ tài khoản trên platform
    -- và đã public profile của họ
    -- SET NULL khi họ xóa tài khoản - quan hệ vẫn còn, chỉ mất link
    linked_person_id    UUID,

    -- ── Tầng 2: Bản chất của mối quan hệ ──────────────────────
    relationship_type   VARCHAR(100)        NOT NULL,
    strength            SMALLINT            NOT NULL,
    is_mutual           BOOLEAN             NOT NULL DEFAULT TRUE,

    -- Ghi chú về mối quan hệ — khác related_bio
    -- Ví dụ: "quen nhau qua dự án X năm 2020, từng có mâu thuẫn nhỏ"
    notes               TEXT,
    since_date          DATE,
    ended_at            DATE,

    -- Ảnh kỷ niệm của mối quan hệ — ví dụ: ảnh chụp chung
    -- Tách biệt với related_avatar_url là ảnh đại diện của họ
    memory_photo_url           VARCHAR(500),

    created_at          TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_relationships
        PRIMARY KEY (id),

    CONSTRAINT fk_relationships_person
        FOREIGN KEY (person_id)
            REFERENCES persons (id)
            ON DELETE CASCADE,

    -- SET NULL thay vì CASCADE - mất account không mất relationship
    CONSTRAINT fk_relationships_linked_person
        FOREIGN KEY (linked_person_id)
            REFERENCES persons (id)
            ON DELETE SET NULL,

    CONSTRAINT relationships_type_check
        CHECK (relationship_type IN ('FAMILY', 'FRIEND', 'COLLEAGUE', 'ROMANTIC', 'MENTOR', 'OTHER')),

    CONSTRAINT relationships_strength_range
        CHECK (strength BETWEEN 1 AND 5),

    CONSTRAINT relationships_gender_check
        CHECK (related_gender IN ('MALE', 'FEMALE', 'OTHER', 'PREFER_NOT_TO_SAY')),

    -- Ngày kết thúc không thể trước ngày bắt đầu
    CONSTRAINT relationship_dates_order
        CHECK ( ended_at IS NULL OR since_date IS NULL OR ended_at >= since_date),

    -- Một person không thể tự link vào quan hệ của chính mình
    CONSTRAINT relationships_no_self_link
        CHECK (linked_person_id != person_id)
);

CREATE TRIGGER trg_relationships_updated_at
    BEFORE UPDATE ON relationships
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE relationships
    IS 'Social network — stores both personal info of contact and relationship context';
COMMENT ON COLUMN relationships.related_name
    IS 'Free-text name — not bound to any platform account';
COMMENT ON COLUMN relationships.related_bio
    IS 'Description of who this person is — written from the dossier owner perspective';
COMMENT ON COLUMN relationships.related_social_links
    IS 'Contact social channels: {"facebook":"...","zalo":"...","instagram":"..."}';
COMMENT ON COLUMN relationships.notes
    IS 'Notes about the relationship itself — how they met, shared history, etc.';
COMMENT ON COLUMN relationships.linked_person_id
    IS 'Optional FK — only set if contact is on platform with public profile';
COMMENT ON COLUMN relationships.memory_photo_url
    IS 'A shared memory photo (e.g. photo together) — distinct from related_avatar_url';
COMMENT ON COLUMN relationships.strength
    IS '1=acquaintance to 5=closest — edge weight for graph centrality metrics';
COMMENT ON COLUMN relationships.is_mutual
    IS 'FALSE = one-directional (e.g. admiring a public figure)';

-- ----------------------------------------------------------------

CREATE TABLE timeline_events
(
    id              UUID                NOT NULL DEFAULT gen_random_uuid(),
    person_id       UUID                NOT NULL,
    title           VARCHAR(200)        NOT NULL,
    description     TEXT,
    event_date      DATE                NOT NULL,
    end_date        DATE,               -- NULL = single-day event, set = duration event (job, school, trip)
    event_type      VARCHAR(20)         NOT NULL DEFAULT 'PERSONAL',
    location        VARCHAR(200),
    mood            VARCHAR(20)         NOT NULL DEFAULT 'NEUTRAL',
    is_milestone    BOOLEAN             NOT NULL DEFAULT FALSE,
    -- Ảnh bìa chính của sự kiện - hiển thị trên timeline card
    cover_image_url VARCHAR(500),
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_timeline_events
        PRIMARY KEY (id),

    CONSTRAINT fk_timeline_events_person
        FOREIGN KEY (person_id)
            REFERENCES persons (id)
            ON DELETE CASCADE,

    CONSTRAINT timeline_events_dates_order
        CHECK (end_date IS NULL OR end_date >= event_date),

    CONSTRAINT timeline_events_type_check
        CHECK (event_type IN ('PERSONAL', 'CAREER', 'EDUCATION', 'TRAVEL', 'OTHER')),

    CONSTRAINT timeline_events_mood_check
        CHECK (mood IN ('POSITIVE', 'NEGATIVE', 'NEUTRAL'))
);

CREATE TRIGGER trg_timeline_events_updated_at
    BEFORE UPDATE ON timeline_events
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE timeline_events
    IS 'Life events for timeline visualization';
COMMENT ON COLUMN timeline_events.end_date
    IS 'Set for duration events: jobs, school, trips. NULL = single-point event';
COMMENT ON COLUMN timeline_events.cover_image_url
    IS 'Hero image displayed on the timeline event card';
COMMENT ON COLUMN timeline_events.mood
    IS 'Used by Intelligence Engine to detect positive/negative life phases over time';
COMMENT ON COLUMN timeline_events.is_milestone
    IS 'Milestone events render prominently on the timeline UI';

-- ----------------------------------------------------------------

CREATE TABLE event_photos
(
    id              UUID                NOT NULL DEFAULT gen_random_uuid(),
    event_id        UUID                NOT NULL,
    photo_url       VARCHAR(500)        NOT NULL,
    caption         VARCHAR(200),
    display_order   SMALLINT            NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_event_photos
        PRIMARY KEY (id),

    CONSTRAINT fk_event_photos_event
        FOREIGN KEY (event_id)
            REFERENCES timeline_events (id)
            ON DELETE CASCADE
);

COMMENT ON TABLE event_photos
    IS 'Photo gallery for timeline events — separate from cover_image_url';

-- ----------------------------------------------------------------

CREATE TABLE dossier_shares
(
    id                      UUID                NOT NULL DEFAULT gen_random_uuid(),
    person_id               UUID                NOT NULL,
    slug                    VARCHAR(100)        NOT NULL,
    is_radar_public         BOOLEAN             NOT NULL DEFAULT FALSE,
    is_graph_public         BOOLEAN             NOT NULL DEFAULT FALSE,
    is_timeline_public      BOOLEAN             NOT NULL DEFAULT FALSE,
    is_media_public         BOOLEAN             NOT NULL DEFAULT FALSE,
    is_relationships_public BOOLEAN             NOT NULL DEFAULT FALSE,
    is_photos_public        BOOLEAN             NOT NULL DEFAULT FALSE,
    share_password_hash     VARCHAR,            -- NULL = Không đặt mật khẩu
    view_count              INTEGER             NOT NULL DEFAULT 0,
    expires_at              TIMESTAMPTZ,        -- NULL
    created_at              TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_dossier_shares
        PRIMARY KEY (id),

    -- Mỗi person chỉ có 1 bộ cài đặt share
    CONSTRAINT dossier_shares_person_unique
        UNIQUE (person_id),

    CONSTRAINT dossier_shares_slug_unique
        UNIQUE (slug),

    CONSTRAINT dossier_shares_view_count_non_negative
        CHECK (view_count >=0),

    CONSTRAINT fk_dossier_shares_person
        FOREIGN KEY (person_id)
            REFERENCES persons (id)
            ON DELETE CASCADE
);

CREATE TRIGGER trg_dossier_shares_updated_at
    BEFORE UPDATE ON dossier_shares
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE dossier_shares
    IS 'Public sharing configuration with per-section privacy controls';
COMMENT ON COLUMN dossier_shares.expires_at
    IS 'NULL = link never expires. Set a future timestamp to auto-expire';
COMMENT ON COLUMN dossier_shares.is_photos_public
    IS 'Privacy control for person_photos gallery section';
COMMENT ON COLUMN dossier_shares.share_password_hash
    IS 'BCrypt hash — NULL means public access, set means password-protected link';
COMMENT ON COLUMN dossier_shares.view_count
    IS 'Incremented atomically on each public dossier page load';