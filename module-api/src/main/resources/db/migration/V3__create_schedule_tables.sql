-- =============================================================================
-- MIGRATION V3: Schedule Domain — Lịch Dạy Định Kỳ & Theo Dõi Buổi Học
-- Tác giả  : TutorSmart Dev Team
-- Phụ thuộc: V2 phải đã chạy (tutor_profiles, students tồn tại)
--            set_updated_at() đã tồn tại từ V1 — KHÔNG tạo lại.
--
-- Thiết kế 2 tầng (Template Pattern):
--   schedules          → "Khuôn mẫu" lịch định kỳ (thứ mấy, giờ nào, môn gì)
--   schedule_sessions  → "Sự thật" từng buổi học cụ thể (ngày cụ thể, kết quả)
--
-- Lý do tách 2 tầng:
--   - Lịch định kỳ có thể thay đổi mà không mất history buổi học đã qua
--   - Có thể thêm buổi ngoài lịch (make-up, extra) mà không cần template
--   - Billing dựa trên schedule_sessions (thực tế), không phải schedules (kế hoạch)
-- =============================================================================


-- =============================================================================
-- BẢNG: schedules
-- Template lịch dạy định kỳ. Ví dụ: "Dạy Toán cho Minh, Thứ 2 & Thứ 4, 17:30"
-- Một cặp (gia sư, học sinh) có thể có nhiều schedules (nhiều môn khác nhau)
-- =============================================================================
CREATE TABLE schedules
(
    -- Primary key
    id                  UUID         PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Quan hệ chính
    tutor_id            UUID         NOT NULL,   -- FK → tutor_profiles
    student_id          UUID         NOT NULL,   -- FK → students

    -- -------------------------------------------------------------------------
    -- Nội dung lịch học
    -- -------------------------------------------------------------------------
    subject             VARCHAR(100) NOT NULL,

    -- day_of_week: ISO 8601 — 1=Thứ Hai, 2=Thứ Ba, ..., 7=Chủ Nhật
    -- Dùng SMALLINT (không phải ENUM) để dễ tính toán ngày (date arithmetic)
    day_of_week         SMALLINT     NOT NULL,

    start_time          TIME         NOT NULL,
    duration_minutes    SMALLINT     NOT NULL    DEFAULT 90, -- Mặc định 90 phút

    -- -------------------------------------------------------------------------
    -- Địa điểm
    -- Ví dụ: "123 Nguyễn Huệ, Q1", "Online - Google Meet", "Tại nhà gia sư"
    -- -------------------------------------------------------------------------
    location            VARCHAR(300),

    -- -------------------------------------------------------------------------
    -- Cấu hình lịch
    -- -------------------------------------------------------------------------
    -- TRUE = lặp lại hàng tuần (phổ biến nhất)
    -- FALSE = chỉ 1 buổi duy nhất
    is_recurring        BOOLEAN      NOT NULL    DEFAULT TRUE,

    is_active           BOOLEAN      NOT NULL    DEFAULT TRUE,

    -- Hiệu lực thời gian của lịch (thêm so với spec gốc — BẮT BUỘC trong thực tế)
    -- Lý do: gia sư thường đổi giờ/thứ nhưng không muốn mất lịch cũ.
    -- effective_from/to cho phép lưu song song lịch cũ và mới.
    effective_from      DATE,                    -- Lịch có hiệu lực từ ngày nào (NULL = từ khi tạo)
    effective_to        DATE,                    -- Lịch hết hiệu lực ngày nào (NULL = vô thời hạn)

    -- -------------------------------------------------------------------------
    -- Timestamps
    -- -------------------------------------------------------------------------
    created_at          TIMESTAMPTZ  NOT NULL    DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL    DEFAULT NOW(),

    -- =========================================================================
    -- CONSTRAINTS
    -- =========================================================================
    CONSTRAINT fk_schedules_tutor
        FOREIGN KEY (tutor_id)
            REFERENCES tutor_profiles (id)
            ON DELETE CASCADE,

    CONSTRAINT fk_schedules_student
        FOREIGN KEY (student_id)
            REFERENCES students (id)
            ON DELETE CASCADE,

    -- Chỉ chấp nhận ngày trong tuần hợp lệ theo ISO 8601
    CONSTRAINT chk_schedules_day_of_week
        CHECK (day_of_week BETWEEN 1 AND 7),

    -- Thời lượng hợp lý: tối thiểu 15 phút, tối đa 8 giờ
    CONSTRAINT chk_schedules_duration_minutes
        CHECK (duration_minutes BETWEEN 15 AND 480),

    -- effective_to phải sau effective_from nếu cả hai đều có giá trị
    CONSTRAINT chk_schedules_effective_dates
        CHECK (effective_from IS NULL
            OR effective_to IS NULL
            OR effective_to >= effective_from)
);

-- Trigger: dùng set_updated_at() đã định nghĩa tại V1
CREATE TRIGGER trg_schedules_updated_at
    BEFORE UPDATE ON schedules
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- -------------------------------------------------------------------------
-- INDEXES cho schedules
-- -------------------------------------------------------------------------

-- Lấy toàn bộ lịch của gia sư (sidebar calendar view)
CREATE INDEX idx_schedules_tutor_id
    ON schedules (tutor_id);

-- Lấy lịch của học sinh (student detail page)
CREATE INDEX idx_schedules_student_id
    ON schedules (student_id);

-- Query quan trọng nhất: "Hôm nay thứ mấy? Lấy lịch active của gia sư hôm nay"
-- Composite index: filter tutor_id + is_active + day_of_week chỉ 1 lần scan
CREATE INDEX idx_schedules_tutor_active_day
    ON schedules (tutor_id, day_of_week)
    WHERE is_active = TRUE;

-- -------------------------------------------------------------------------
-- COMMENTS
-- -------------------------------------------------------------------------
COMMENT ON TABLE schedules IS
    'Template lịch dạy định kỳ. Mỗi record = 1 slot dạy trong tuần. '
    'Gia sư dạy 3 môn cho 1 học sinh → 3 schedule records riêng biệt.';

COMMENT ON COLUMN schedules.day_of_week IS
    'ISO 8601: 1=Thứ Hai, 2=Thứ Ba, 3=Thứ Tư, 4=Thứ Năm, 5=Thứ Sáu, 6=Thứ Bảy, 7=Chủ Nhật.';
COMMENT ON COLUMN schedules.duration_minutes IS
    'Thời lượng buổi học tính bằng phút. Mặc định 90 phút (1.5 giờ).';
COMMENT ON COLUMN schedules.is_recurring IS
    'TRUE = lặp lại mỗi tuần theo day_of_week. FALSE = chỉ xảy ra 1 lần duy nhất.';
COMMENT ON COLUMN schedules.effective_from IS
    'Lịch này có hiệu lực từ ngày nào. NULL = từ ngày tạo record.';
COMMENT ON COLUMN schedules.effective_to IS
    'Lịch này hết hiệu lực ngày nào. NULL = vô thời hạn (đang dùng).';


-- =============================================================================
-- BẢNG: schedule_sessions
-- Bản ghi từng buổi học CỤ THỂ. "Source of truth" cho calendar, billing, báo cáo.
--
-- Nguồn gốc của 1 session:
--   1. Auto-generated: hệ thống tạo tự động từ schedules template (định kỳ hàng tuần)
--   2. Manual       : gia sư tạo tay (buổi bù, buổi học thêm ngoài lịch)
--
-- schedule_id có thể NULL vì buổi bù / extra không cần gắn với template lịch định kỳ
-- =============================================================================
CREATE TABLE schedule_sessions
(
    -- Primary key
    id                      UUID         PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Quan hệ với lịch template (NULL = buổi ngoài lịch)
    schedule_id             UUID,

    -- Denormalize tutor_id & student_id để query calendar nhanh hơn
    -- (tránh JOIN qua schedules mỗi lần render calendar view)
    tutor_id                UUID         NOT NULL,
    student_id              UUID         NOT NULL,

    -- -------------------------------------------------------------------------
    -- Thời gian buổi học cụ thể
    -- -------------------------------------------------------------------------
    session_date            DATE         NOT NULL,
    start_time              TIME         NOT NULL,
    end_time                TIME         NOT NULL,   -- = start_time + duration_minutes

    -- -------------------------------------------------------------------------
    -- Trạng thái buổi học
    -- Vòng đời điển hình:
    --   SCHEDULED → COMPLETED          (buổi học bình thường)
    --   SCHEDULED → STUDENT_ABSENT     (học sinh nghỉ, có thể cần bù)
    --   SCHEDULED → TUTOR_ABSENT       (gia sư nghỉ, cần bù)
    --   SCHEDULED → CANCELLED          (hủy hẳn, không bù)
    --   (new record) → MAKEUP          (buổi bù được tạo để bù cho buổi absent)
    -- -------------------------------------------------------------------------
    status                  VARCHAR(20)  NOT NULL    DEFAULT 'SCHEDULED',

    -- -------------------------------------------------------------------------
    -- Nội dung buổi học (gia sư điền sau khi dạy xong)
    -- -------------------------------------------------------------------------
    tutor_notes             TEXT,                    -- Nhận xét học sinh buổi này
    homework                TEXT,                    -- Bài tập đã giao
    next_topic              TEXT,                    -- Chủ đề cho buổi sau

    -- -------------------------------------------------------------------------
    -- Học phí buổi này
    -- fee_amount NULL = dùng fee_amount mặc định của student record
    -- -------------------------------------------------------------------------
    fee_amount              NUMERIC(12, 0),
    fee_status              VARCHAR(30)  NOT NULL    DEFAULT 'UNPAID',

    -- -------------------------------------------------------------------------
    -- Liên kết buổi bù (thêm so với spec gốc — cần thiết để track vòng đời)
    -- Nếu đây là buổi bù (status=MAKEUP), trỏ về buổi gốc bị nghỉ.
    -- SET NULL khi buổi gốc bị xóa → giữ buổi bù, chỉ mất link.
    -- -------------------------------------------------------------------------
    makeup_for_session_id   UUID,

    -- -------------------------------------------------------------------------
    -- Timestamps
    -- -------------------------------------------------------------------------
    created_at              TIMESTAMPTZ  NOT NULL    DEFAULT NOW(),
    updated_at              TIMESTAMPTZ  NOT NULL    DEFAULT NOW(),

    -- =========================================================================
    -- CONSTRAINTS
    -- =========================================================================

    -- SET NULL khi schedule template bị xóa → vẫn giữ history buổi học
    CONSTRAINT fk_sessions_schedule
        FOREIGN KEY (schedule_id)
            REFERENCES schedules (id)
            ON DELETE SET NULL,

    CONSTRAINT fk_sessions_tutor
        FOREIGN KEY (tutor_id)
            REFERENCES tutor_profiles (id)
            ON DELETE CASCADE,

    CONSTRAINT fk_sessions_student
        FOREIGN KEY (student_id)
            REFERENCES students (id)
            ON DELETE CASCADE,

    -- Self-reference: buổi bù trỏ về buổi gốc bị nghỉ
    CONSTRAINT fk_sessions_makeup_for
        FOREIGN KEY (makeup_for_session_id)
            REFERENCES schedule_sessions (id)
            ON DELETE SET NULL,

    CONSTRAINT chk_sessions_status
        CHECK (status IN ('SCHEDULED', 'COMPLETED', 'STUDENT_ABSENT',
                          'TUTOR_ABSENT', 'CANCELLED', 'MAKEUP')),

    CONSTRAINT chk_sessions_fee_status
        CHECK (fee_status IN ('UNPAID', 'PAID', 'INCLUDED_IN_MONTHLY', 'WAIVED')),

    -- end_time phải sau start_time
    CONSTRAINT chk_sessions_time_order
        CHECK (end_time > start_time),

    -- Học phí không âm
    CONSTRAINT chk_sessions_fee_amount
        CHECK (fee_amount IS NULL OR fee_amount >= 0),

    -- Buổi bù không thể tự trỏ vào chính nó
    CONSTRAINT chk_sessions_no_self_makeup
        CHECK (makeup_for_session_id IS NULL OR makeup_for_session_id <> id)
);

-- Trigger: dùng set_updated_at() đã định nghĩa tại V1
CREATE TRIGGER trg_sessions_updated_at
    BEFORE UPDATE ON schedule_sessions
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- -------------------------------------------------------------------------
-- INDEXES cho schedule_sessions
-- -------------------------------------------------------------------------

-- [QUAN TRỌNG NHẤT] Xem lịch theo tuần/tháng của gia sư
-- "Cho tôi thấy tất cả buổi học từ ngày A đến ngày B"
CREATE INDEX idx_sessions_tutor_date
    ON schedule_sessions (tutor_id, session_date DESC);

-- Lấy lịch sử buổi học của 1 học sinh (student detail page)
CREATE INDEX idx_sessions_student_date
    ON schedule_sessions (student_id, session_date DESC);

-- [BILLING] Tổng kết buổi học trong tháng để tính tiền
-- Query pattern: tutor_id=X AND student_id=Y AND session_date BETWEEN ... AND ...
CREATE INDEX idx_sessions_billing
    ON schedule_sessions (tutor_id, student_id, session_date);

-- Lọc buổi sắp tới (SCHEDULED) để hiển thị upcoming sessions & gửi nhắc nhở
CREATE INDEX idx_sessions_upcoming
    ON schedule_sessions (tutor_id, session_date, start_time)
    WHERE status = 'SCHEDULED';

-- Tìm session theo schedule template (khi cần update/cancel hàng loạt)
CREATE INDEX idx_sessions_schedule_id
    ON schedule_sessions (schedule_id)
    WHERE schedule_id IS NOT NULL;

-- -------------------------------------------------------------------------
-- COMMENTS
-- -------------------------------------------------------------------------
COMMENT ON TABLE schedule_sessions IS
    'Từng buổi học cụ thể — "source of truth" cho calendar, billing và báo cáo. '
    'Được tạo tự động từ schedules template hoặc thêm thủ công bởi gia sư.';

COMMENT ON COLUMN schedule_sessions.schedule_id IS
    'FK → schedules.id (nullable). NULL = buổi ngoài lịch định kỳ (buổi bù, extra).';
COMMENT ON COLUMN schedule_sessions.status IS
    'SCHEDULED (chưa học) | COMPLETED (đã học) | STUDENT_ABSENT (HS nghỉ) | '
    'TUTOR_ABSENT (GS nghỉ) | CANCELLED (hủy hẳn, không bù) | MAKEUP (buổi bù).';
COMMENT ON COLUMN schedule_sessions.fee_status IS
    'UNPAID (chưa thu) | PAID (đã thu riêng buổi này) | '
    'INCLUDED_IN_MONTHLY (gộp vào học phí tháng) | WAIVED (miễn buổi này).';
COMMENT ON COLUMN schedule_sessions.makeup_for_session_id IS
    'Self-FK → schedule_sessions.id. Nếu đây là buổi bù (MAKEUP), '
    'trỏ về buổi gốc bị nghỉ. SET NULL khi buổi gốc bị xóa.';
COMMENT ON COLUMN schedule_sessions.tutor_notes IS
    'Nhận xét của gia sư sau buổi học: tiến độ, thái độ, điểm cần cải thiện.';
COMMENT ON COLUMN schedule_sessions.fee_amount IS
    'Học phí buổi này (VNĐ). NULL = dùng fee_amount mặc định từ students record.';