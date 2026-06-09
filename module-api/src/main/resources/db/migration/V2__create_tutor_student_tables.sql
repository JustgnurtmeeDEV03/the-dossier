-- =============================================================================
-- MIGRATION V2: Core Domain — Tutor Profile & Student Management
-- Tác giả  : TutorSmart Admin
-- Ngày tạo : 2026
-- Mô tả    : Tạo bảng hồ sơ gia sư (tutor_profiles) và danh sách học sinh
--            (students). Đây là nền tảng của toàn bộ hệ thống — tất cả các
--            module sau (schedule, billing) đều phụ thuộc vào V2.
--
-- =============================================================================
-- BẢNG: tutor_profiles
-- Hồ sơ nghề nghiệp của gia sư. Quan hệ 1-1 với bảng users.
-- Tách khỏi users để giữ module-auth thuần túy (auth concerns only).
-- =============================================================================
CREATE TABLE tutor_profiles
(
    -- Primary key
    id              UUID                PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Liên kết với user account (1 user = 1 tutor profile, UNIQUE enforced)
    user_id         UUID                NOT NULL,

    -- Thông tin hiển thị
    display_name    VARCHAR(100)        NOT NULL,
    phone           VARCHAR(20),

    -- Danh sách môn dạy, dùng PostgreSQL native array để tránh bảng pivot thừa.
    -- Phù hợp vì subjects không cần query relation phức tạp.
    -- Ví dụ: ARRAY['Toán', 'Vật Lý', 'Hóa Học']
    subjects        TEXT[]              NOT NULL                DEFAULT '{}',

    -- Học phí mặc định (đơn vị VNĐ - không cần phần thập phân)
    -- NUMERIC(12,0): Hỗ trợ tối đa 999.999.999.999 VNĐ — an toàn tuyệt đối
    hourly_rate     NUMERIC(12, 0),     -- Giá theo giờ (nếu tính theo giờ)
    session_rate    NUMERIC(12, 0),     -- Giá theo buổi (mặc định phổ biến hơn)

    -- Thông tin bổ sung
    bio             TEXT,               -- Giới thiệu bản thân, kinh nghiệm
    avatar_url      TEXT,               -- URL đại diện (lưu trên S3/CDN)

    -- Metadata
    is_active       BOOLEAN             NOT NULL                DEFAULT TRUE,
    created_at      TIMESTAMPTZ         NOT NULL                DEFAULT NOW(),
    updated_at      TIMESTAMPTZ         NOT NULL                DEFAULT NOW(),


    -- CONSTRAINTS
    -- FK: liên kết với user account. CASCADE DELETE để khi xóa user thì toàn bộ dữ liệu
    --  nghề nghiệp cũng sẽ bị xóa theo (GDPR-friendly)
    CONSTRAINT fk_tutor_profiles_user
        FOREIGN KEY (user_id)
            REFERENCES users(id)
            ON DELETE CASCADE,

    -- Đảm bảo 1 user không thể có 2 tutor profile
    CONSTRAINT uq_tutor_profiles_user_id
        UNIQUE (user_id),

    -- Học phí không được âm
    CONSTRAINT chk_tutor_profiles_hourly_rate
        CHECK (hourly_rate IS NULL OR hourly_rate >= 0),

    CONSTRAINT chk_tutor_profiles_session_rate
        CHECK  (session_rate IS NULL OR session_rate >=0)
);

-- Trigger: tự động set updated_at = NOW() mỗi khi UPDATE
CREATE TRIGGER trg_tutor_profiles_updated_at
    BEFORE UPDATE ON tutor_profiles
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

-- -------------------------------------------------------------------------
-- INDEXES cho tutor_profiles
-- -------------------------------------------------------------------------

-- Lookup user_id -> tutor_profile_id (Thực hiện ở MỌI API request khi auth)
-- Đây là index quan trọng nhất của bảng này
CREATE INDEX idx_tutor_profiles_user_id
    ON tutor_profiles (user_id);

-- Lọc các gia sư đang hoạt động (Admin Dashboard, analytics sau này)
CREATE INDEX idx_tutor_profiles_active
    ON tutor_profiles (is_active)
    WHERE is_active = TRUE;

-- Tìm kiếm gia sư theo môn dạy - GIN index bắt buộc cho array type
-- Dùng cho: "Tìm gia sư dạy Toán" (feature marketplace tương lai)
CREATE INDEX idx_tutor_profiles_subjects_gin
    ON tutor_profiles USING GIN (subjects);

-- -------------------------------------------------------------------------
-- COMMENTS
-- -------------------------------------------------------------------------

COMMENT ON TABLE tutor_profiles IS
        'Hồ sơ nghề nghiệp của gia sư. Quan hệ 1-1 với bảng users.'
        'Chứa thông tin nghề nghiệp, tách biệt hoàn toàn với auth module.';

COMMENT ON COLUMN tutor_profiles.user_id IS
        'FK -> users.id. Mỗi user chỉ có đúng 1 tutor profile (UNIQUE constraint)';
COMMENT ON COLUMN tutor_profiles.subjects IS
        'Danh sách môn dạy. PostgreSQL TEXT array. Ví dụ: {"Toán", "Vật Lý", "Tiếng Anh"}';
COMMENT ON COLUMN tutor_profiles.hourly_rate IS
        'Học phí theo giờ (VNĐ). NULL nếu giá sư không dạy theo giờ.';
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
    id              UUID                PRIMARY KEY DEFAULT gen_random_uuid

    -- Gia sư quản lý học sinh này
    tutor_id        UUID                NOT NULL,

    -- Thông tin học sinh
    full_name       VARCHAR(100)        NOT NULL,

    -- grade: lưu dạng text để linh hoạt với cả "Lớp 5", "10A1", "Lớp 12"
    grade           VARCHAR(30),
    school          VARCHAR(200),

    -- Môn học với gia sư này (có thể khác subjects tổng quát của gia sư)
    subject         TEXT[]              NOT NULL,               DEFAULT '{}',

    -- Thông tin phụ huynh
    parent_name     VARCHAR(100),
    parent_phone    VARCHAR(20),
    parent_email    VARCHAR(255),

    -- Zalo ID để gửi báo cáo tự động qua Zalo OA (feature cốt lõi của TutorSmart)
    parent_zalo_id  VARCHAR(100),

    -- Học phí
    -- fee-type = PER_SESSION hoặc PER_HOUR. Đổi thành "fee_amount" để ý nghĩa phụ thuộc vào fee_type:
    -- PER_SESSION -> Số tiền mỗi buổi học
    -- PER_MONTH -> Số tiền cố định mỗi tháng
    -- PER_HOUR -> Số tiền mỗi giờ học
    fee_amount      NUMERIC(12, 0),
    fee_type        VARCHAR(20)         NOT NULL                DEFAULT 'PER_SESSION',

    -- Trạng thái & metadata
    notes           TEXT,               -- Ghi chú riêng của gia sư về học sinh
    is_active       BOOLEAN             NOT NULL                DEFAULT TRUE,
    start_date      DATE,               -- Ngày bắt đầu học (NULL = chưa xác định)

    -- Timestamps
    created_at      TIMESTAMPTZ         NOT NULL                DEFAULT NOW(),
    updated_at      TIMESTAMPTZ         NOT NULL                DEFAULT NOW(),


    -- CONSTRAINTS
    -- FK: Học sinh thuộc về tutor_profile (Không phải user trực tiếp)
    -- CASCADE DELETE: xóa gia sư -> Xóa toàn bộ học sinh liên quan
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
        CHECK (parent_email IS NULL OR parent_email * '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
);

-- Trigger: tự động cập nhật updated_at
CREATE TRIGGER trg_students_updated_at
    BEFORE UPDATE
    ON students
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

-- -------------------------------------------------------------------------
-- INDEXES cho students
-- -------------------------------------------------------------------------

-- Index chính: Lấy danh sách học sinh của gia sư (cực kỳ thường xuyên)
CREATE INDEX idx_students_tutor_id
    ON students (tutor_id);

-- Index thường dùng nhất trong UI: Danh sách học sinh đang active
-- Partial index tiết kiệm không gian và nhanh hơn full index
CREATE INDEX idx_students_tutor_active
    ON students (tutor_id, full_name)
    WHERE is_active = TRUE;

-- Lookup theo số điện thoại phụ huynh (Nhận SMS/ZALO notification)
CREATE INDEX idx_students_parent_phone
    ON students (parent_phone)
    WHERE parent_phone IS NOT NULL;

-- Tìm học sinh theo môn học
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
    'Ví dụ: 200000 + PER_SESSION = 200k/buổi.';
COMMENT ON COLUMN students.fee_type IS
    'PER_SESSION (theo buổi) | PER_MONTH (cố định theo tháng) | PER_HOUR (theo giờ).';
COMMENT ON COLUMN students.notes IS
    'Ghi chú riêng của gia sư: điểm mạnh/yếu, tính cách, cần lưu ý khi dạy.';
COMMENT ON COLUMN students.start_date IS
    'Ngày bắt đầu học. Dùng để: tính thâm niên, lọc học sinh theo thời gian.';