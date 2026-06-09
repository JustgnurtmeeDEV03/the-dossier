-- =============================================================================
-- MIGRATION V2: Core Domain — Tutor Profile & Student Management
-- Tác giả  : TutorSmart Dev Team
-- Phụ thuộc: V1 phải đã chạy (bảng users tồn tại, hàm set_updated_at() tồn tại)
--
-- Bảng tạo mới:
--   tutor_profiles  → Hồ sơ nghề nghiệp của gia sư (1-1 với users)
--   students        → Danh sách học sinh thuộc về từng gia sư
--
-- LƯU Ý: KHÔNG tạo lại hàm set_updated_at() vì đã được định nghĩa tại V1.
--        Tất cả trigger trong file này đều gọi set_updated_at() từ V1.
-- =============================================================================


-- =============================================================================
-- BẢNG: tutor_profiles
-- Hồ sơ nghề nghiệp của gia sư. Quan hệ 1-1 với bảng users.
-- Tách khỏi users để giữ module-auth thuần túy (auth concerns only).
-- =============================================================================
CREATE TABLE tutor_profiles
(
    -- Primary key
    id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Liên kết với user account (1 user = 1 tutor profile, UNIQUE enforced)
    user_id         UUID          NOT NULL,

    -- -------------------------------------------------------------------------
    -- Thông tin hiển thị
    -- -------------------------------------------------------------------------
    display_name    VARCHAR(100)  NOT NULL,
    phone           VARCHAR(20),

    -- Danh sách môn dạy, dùng PostgreSQL native array để tránh bảng pivot thừa.
    -- Phù hợp vì subjects không cần query relation phức tạp.
    -- Ví dụ: ARRAY['Toán', 'Vật Lý', 'Hóa Học']
    subjects        TEXT[]        NOT NULL    DEFAULT '{}',

    -- -------------------------------------------------------------------------
    -- Học phí mặc định (đơn vị VNĐ)
    -- NUMERIC(12,0): hỗ trợ tối đa 999.999.999.999 VNĐ
    -- -------------------------------------------------------------------------
    hourly_rate     NUMERIC(12, 0),     -- Giá theo giờ
    session_rate    NUMERIC(12, 0),     -- Giá theo buổi (phổ biến hơn)

    -- -------------------------------------------------------------------------
    -- Thông tin bổ sung
    -- -------------------------------------------------------------------------
    bio             TEXT,               -- Giới thiệu bản thân, kinh nghiệm
    avatar_url      TEXT,               -- URL ảnh đại diện (lưu trên S3/CDN)

    -- -------------------------------------------------------------------------
    -- Metadata
    -- -------------------------------------------------------------------------
    is_active       BOOLEAN       NOT NULL    DEFAULT TRUE,
    created_at      TIMESTAMPTZ   NOT NULL    DEFAULT NOW(),
    updated_at      TIMESTAMPTZ   NOT NULL    DEFAULT NOW(),

    -- =========================================================================
    -- CONSTRAINTS
    -- =========================================================================

    -- FK → users. CASCADE DELETE: xóa user → xóa toàn bộ dữ liệu nghề nghiệp (GDPR-friendly)
    CONSTRAINT fk_tutor_profiles_user
        FOREIGN KEY (user_id)
            REFERENCES users (id)
            ON DELETE CASCADE,

    -- Đảm bảo 1 user không thể có 2 tutor profile
    CONSTRAINT uq_tutor_profiles_user_id
        UNIQUE (user_id),

    -- Học phí không được âm
    CONSTRAINT chk_tutor_profiles_hourly_rate
        CHECK (hourly_rate IS NULL OR hourly_rate >= 0),

    CONSTRAINT chk_tutor_profiles_session_rate
        CHECK (session_rate IS NULL OR session_rate >= 0)
);

-- Trigger: dùng set_updated_at() đã định nghĩa tại V1
CREATE TRIGGER trg_tutor_profiles_updated_at
    BEFORE UPDATE ON tutor_profiles
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- -------------------------------------------------------------------------
-- INDEXES cho tutor_profiles
-- -------------------------------------------------------------------------

-- Lookup user_id → tutor_profile (thực hiện ở MỌI API request sau khi auth)
CREATE INDEX idx_tutor_profiles_user_id
    ON tutor_profiles (user_id);

-- Lọc gia sư đang hoạt động (admin dashboard, analytics)
CREATE INDEX idx_tutor_profiles_active
    ON tutor_profiles (is_active)
    WHERE is_active = TRUE;

-- Tìm kiếm gia sư theo môn dạy — GIN index bắt buộc cho array type
CREATE INDEX idx_tutor_profiles_subjects_gin
    ON tutor_profiles USING GIN (subjects);

-- -------------------------------------------------------------------------
-- COMMENTS
-- -------------------------------------------------------------------------
COMMENT ON TABLE tutor_profiles IS
    'Hồ sơ nghề nghiệp của gia sư. Quan hệ 1-1 với bảng users. '
    'Chứa thông tin nghề nghiệp, tách biệt hoàn toàn với auth module.';

COMMENT ON COLUMN tutor_profiles.user_id IS
    'FK → users.id. Mỗi user chỉ có đúng 1 tutor profile (UNIQUE constraint).';
COMMENT ON COLUMN tutor_profiles.subjects IS
    'Danh sách môn dạy. PostgreSQL TEXT array. Ví dụ: {Toán,"Vật Lý","Tiếng Anh"}';
COMMENT ON COLUMN tutor_profiles.hourly_rate IS
    'Học phí theo giờ (VNĐ). NULL nếu gia sư không dạy theo giờ.';
COMMENT ON COLUMN tutor_profiles.session_rate IS
    'Học phí theo buổi (VNĐ). Đây là mức phí DEFAULT khi tạo lịch dạy.';
COMMENT ON COLUMN tutor_profiles.avatar_url IS
    'Đường dẫn ảnh đại diện. Lưu URL ngoài (S3/Cloudinary), không lưu binary.';


-- =============================================================================
-- BẢNG: students
-- Danh sách học sinh của từng gia sư. Dữ liệu core nhất của hệ thống.
-- Mỗi học sinh thuộc về 1 gia sư. Gia sư xóa → học sinh xóa theo.
-- =============================================================================
CREATE TABLE students
(
    -- Primary key
    id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Gia sư quản lý học sinh này
    tutor_id        UUID          NOT NULL,

    -- -------------------------------------------------------------------------
    -- Thông tin học sinh
    -- -------------------------------------------------------------------------
    full_name       VARCHAR(100)  NOT NULL,

    -- grade: lưu dạng text để linh hoạt với cả "Lớp 5", "10A1", "12 Toán", "Đại học"
    grade           VARCHAR(30),
    school          VARCHAR(200),

    -- Môn học với gia sư này (có thể khác subjects tổng quát của tutor_profile)
    subjects        TEXT[]        NOT NULL    DEFAULT '{}',

    -- -------------------------------------------------------------------------
    -- Thông tin liên hệ phụ huynh
    -- -------------------------------------------------------------------------
    parent_name     VARCHAR(100),
    parent_phone    VARCHAR(20),
    parent_email    VARCHAR(255),

    -- Zalo ID để gửi báo cáo tự động qua Zalo OA (feature cốt lõi TutorSmart)
    parent_zalo_id  VARCHAR(100),

    -- -------------------------------------------------------------------------
    -- Học phí
    --
    -- ĐỔI TÊN so với spec gốc: "monthly_fee" → "fee_amount"
    -- Lý do: "monthly_fee" sai ngữ nghĩa khi fee_type = PER_SESSION hoặc PER_HOUR.
    -- fee_amount kết hợp với fee_type mới có đầy đủ ý nghĩa:
    --   PER_SESSION → số tiền mỗi buổi học
    --   PER_MONTH   → số tiền cố định mỗi tháng
    --   PER_HOUR    → số tiền mỗi giờ học
    -- -------------------------------------------------------------------------
    fee_amount      NUMERIC(12, 0),
    fee_type        VARCHAR(20)   NOT NULL    DEFAULT 'PER_SESSION',

    -- -------------------------------------------------------------------------
    -- Trạng thái & metadata
    -- -------------------------------------------------------------------------
    notes           TEXT,                   -- Ghi chú riêng của gia sư về học sinh
    is_active       BOOLEAN       NOT NULL    DEFAULT TRUE,
    start_date      DATE,                   -- Ngày bắt đầu học (NULL = chưa xác định)

    -- -------------------------------------------------------------------------
    -- Timestamps
    -- -------------------------------------------------------------------------
    created_at      TIMESTAMPTZ   NOT NULL    DEFAULT NOW(),
    updated_at      TIMESTAMPTZ   NOT NULL    DEFAULT NOW(),

    -- =========================================================================
    -- CONSTRAINTS
    -- =========================================================================

    -- FK → tutor_profiles (không phải users trực tiếp)
    -- CASCADE DELETE: xóa tutor profile → xóa toàn bộ học sinh liên quan
    CONSTRAINT fk_students_tutor
        FOREIGN KEY (tutor_id)
            REFERENCES tutor_profiles (id)
            ON DELETE CASCADE,

    -- Chỉ chấp nhận 3 kiểu tính phí đã định nghĩa
    CONSTRAINT chk_students_fee_type
        CHECK (fee_type IN ('PER_SESSION', 'PER_MONTH', 'PER_HOUR')),

    -- Học phí không được âm (0 = miễn phí, NULL = chưa set)
    CONSTRAINT chk_students_fee_amount
        CHECK (fee_amount IS NULL OR fee_amount >= 0),

    -- Email phụ huynh phải hợp lệ nếu có
    CONSTRAINT chk_students_parent_email
        CHECK (parent_email IS NULL
            OR parent_email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
    );

-- Trigger: dùng set_updated_at() đã định nghĩa tại V1
CREATE TRIGGER trg_students_updated_at
    BEFORE UPDATE ON students
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- -------------------------------------------------------------------------
-- INDEXES cho students
-- -------------------------------------------------------------------------

-- Index chính: lấy danh sách học sinh của gia sư (cực kỳ thường xuyên)
CREATE INDEX idx_students_tutor_id
    ON students (tutor_id);

-- Partial index: danh sách học sinh đang active, sort theo tên
-- Đây là query thường dùng nhất trong UI (sidebar, dropdown chọn học sinh)
CREATE INDEX idx_students_tutor_active
    ON students (tutor_id, full_name)
    WHERE is_active = TRUE;

-- Lookup theo số điện thoại phụ huynh (nhận SMS/Zalo notification)
CREATE INDEX idx_students_parent_phone
    ON students (parent_phone)
    WHERE parent_phone IS NOT NULL;

-- Tìm học sinh theo môn học (GIN index cho array type)
CREATE INDEX idx_students_subjects_gin
    ON students USING GIN (subjects);

-- -------------------------------------------------------------------------
-- COMMENTS
-- -------------------------------------------------------------------------
COMMENT ON TABLE students IS
    'Danh sách học sinh của gia sư. Mỗi học sinh thuộc về đúng 1 gia sư.';

COMMENT ON COLUMN students.tutor_id IS
    'FK → tutor_profiles.id. Học sinh bị xóa nếu tutor profile bị xóa.';
COMMENT ON COLUMN students.grade IS
    'Lớp học. Dạng text để linh hoạt: "Lớp 5", "10A1", "12 Toán", "Đại học".';
COMMENT ON COLUMN students.subjects IS
    'Môn học với gia sư này. Có thể chỉ là subset của tutor_profiles.subjects.';
COMMENT ON COLUMN students.parent_zalo_id IS
    'Zalo ID phụ huynh. Dùng để gửi báo cáo tự động qua Zalo OA API.';
COMMENT ON COLUMN students.fee_amount IS
    'Mức học phí cơ bản (VNĐ). Ý nghĩa phụ thuộc fee_type. '
    'Ví dụ: 200000 + PER_SESSION = 200.000đ/buổi.';
COMMENT ON COLUMN students.fee_type IS
    'PER_SESSION (theo buổi) | PER_MONTH (cố định theo tháng) | PER_HOUR (theo giờ).';
COMMENT ON COLUMN students.notes IS
    'Ghi chú riêng của gia sư: điểm mạnh/yếu, tính cách, cần lưu ý khi dạy.';
COMMENT ON COLUMN students.start_date IS
    'Ngày bắt đầu học. Dùng để: tính thâm niên, lọc học sinh theo thời gian.';