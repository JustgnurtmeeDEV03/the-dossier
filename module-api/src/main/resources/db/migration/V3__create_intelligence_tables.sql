-- ================================================================
-- V3: Intelligence Engine tables
-- person_scores  : cached psychological dimension scores
-- person_insights: generated "classified memo" snippets
-- ================================================================

CREATE TABLE person_scores
(
    id                  UUID                NOT NULL DEFAULT gen_random_uuid(),
    person_id           UUID                NOT NULL,
    openness            DECIMAL(5,2)        NOT NULL DEFAULT 0.00,
    conscientiousness   DECIMAL(5,2)        NOT NULL DEFAULT 0.00,
    introversion        DECIMAL(5,2)        NOT NULL DEFAULT 0.00,
    romanticism         DECIMAL(5,2)        NOT NULL DEFAULT 0.00,
    analytical          DECIMAL(5,2)        NOT NULL DEFAULT 0.00,
    media_item_count    INTEGER             NOT NULL DEFAULT 0,
    algorithm_version   VARCHAR(20)         NOT NULL DEFAULT 'v1',
    -- 0.00 = không đáng tin (< 5 items), 1.00 = rất tin cậy (100+ items)
    confidence_level    DECIMAL(3,2)        NOT NULL DEFAULT 0.00,
    computed_at         TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    created_at          TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_person_scores
        PRIMARY KEY (id),

    -- Mỗi person chỉ có một bộ điểm hiện tại
    CONSTRAINT person_scores_person_unique
        UNIQUE (person_id),

    CONSTRAINT fk_person_scores_person
        FOREIGN KEY (person_id)
            REFERENCES persons (id)
            ON DELETE CASCADE,

    -- Tất cả điểm phải trong khoảng 0-100
    CONSTRAINT person_scores_openness_range
        CHECK (openness BETWEEN 0 AND 100),
    CONSTRAINT person_scores_conscientiousness_range
        CHECK (conscientiousness BETWEEN 0 AND 100),
    CONSTRAINT person_scores_introversion_range
        CHECK (introversion BETWEEN 0 AND 100),
    CONSTRAINT person_scores_romanticism_range
        CHECK (romanticism BETWEEN 0 AND 100),
    CONSTRAINT person_scores_analytical_range
        CHECK (analytical BETWEEN 0 AND 100),

    CONSTRAINT person_scores_confidence_range
        CHECK (confidence_level BETWEEN 0 AND 1),

    CONSTRAINT person_scores_item_count_non_negative
        CHECK (media_item_count >= 0)
);

CREATE TRIGGER trg_person_scores_updated_at
    BEFORE UPDATE ON person_scores
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE person_scores
    IS 'Cached psychological dimension scores — recomputed when media_items change';
COMMENT ON COLUMN person_scores.computed_at
    IS 'Timestamp of last computation — compare with media_items.updated_at to decide if stale';
COMMENT ON COLUMN person_scores.media_item_count
    IS 'Number of COMPLETED items used in last computation — 0 means scores are meaningless';
COMMENT ON COLUMN person_scores.openness
    IS 'DECIMAL(5,2): total 5 digits, 2 decimal places → range 0.00 to 100.00';
COMMENT ON COLUMN person_scores.algorithm_version
    IS 'Scoring algorithm version — allows recompute when algorithm changes';
COMMENT ON COLUMN person_scores.confidence_level
    IS '0.00=unreliable (<5 items) to 1.00=highly reliable (100+ items). UI shows warning below 0.30';

-- ----------------------------------------------------------------

CREATE TABLE person_insights
(
    id                  UUID                NOT NULL DEFAULT gen_random_uuid(),
    person_id           UUID                NOT NULL,
    insight_type        VARCHAR(30)         NOT NULL,
    content             TEXT                NOT NULL,
    source_entity_ids   JSONB               NOT NULL DEFAULT '[]',
    expires_at          TIMESTAMPTZ,        -- NULL = không hết hạn, set = tự vô hiệu hóa
    is_active           BOOLEAN             NOT NULL DEFAULT TRUE,
    generated_at        TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    created_at          TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_person_insights
        PRIMARY KEY (id),

    CONSTRAINT fk_person_insights_person
        FOREIGN KEY (person_id)
            REFERENCES persons (id)
            ON DELETE CASCADE,

    CONSTRAINT person_insights_type_check
        CHECK (insight_type IN ('MEDIA_PATTERN', 'RELATIONSHIP_ROLE','TIMELINE_SUMMARY'))
);

COMMENT ON TABLE person_insights
    IS 'Generated intelligence report snippets — the "classified memos" in the UI';
COMMENT ON COLUMN person_insights.is_active
    IS 'Only active=TRUE insights are displayed — old insights kept for history/audit';
COMMENT ON COLUMN person_insights.insight_type
    IS 'MEDIA_PATTERN: from media habits | RELATIONSHIP_ROLE: from graph | TIMELINE_SUMMARY: from events';
COMMENT ON COLUMN person_insights.source_entity_ids
    IS 'JSON array of UUIDs — e.g. ["uuid1","uuid2"] — enables drill-down explanation';
COMMENT ON COLUMN person_insights.expires_at
    IS 'Auto-expire after significant data changes. NULL = permanent until manually deactivated';