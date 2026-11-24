ICT371 Advanced Database - Question 10: Scholarship Application Assessment
-- DBMS: PostgreSQL

DROP TABLE IF EXISTS scholarship_summary, status_audit, assessments, applications CASCADE;

-- (a) Database and Seed Data
CREATE TABLE applications (
    application_id SERIAL PRIMARY KEY,
    applicant_name VARCHAR(100) NOT NULL,
    gpa NUMERIC(3, 2) NOT NULL CHECK (gpa >= 0.00 AND gpa <= 4.00),
    household_income NUMERIC(12, 2) NOT NULL CHECK (household_income >= 0),
    status VARCHAR(15) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE assessments (
    assessment_id SERIAL PRIMARY KEY,
    application_id INT UNIQUE NOT NULL REFERENCES applications(application_id),
    score INT NOT NULL CHECK (score >= 0 AND score <= 100),
    assessed_on DATE NOT NULL
);

CREATE TABLE status_audit (
    audit_id SERIAL PRIMARY KEY,
    application_id INT NOT NULL REFERENCES applications(application_id),
    old_status VARCHAR(15) NOT NULL,
    new_status VARCHAR(15) NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE scholarship_summary (
    summary_date DATE PRIMARY KEY,
    assessed_count INT NOT NULL DEFAULT 0,
    approved_count INT NOT NULL DEFAULT 0,
    rejected_count INT NOT NULL DEFAULT 0
);

-- Six applications spanning high/low GPA and income profiles
INSERT INTO applications (applicant_name, gpa, household_income, status) VALUES
('Chisomo Banda',   3.85, 8000.00,  'PENDING'), -- High GPA, low income -> APPROVED
('Misozi Phiri',    3.40, 12000.00, 'PENDING'), -- Good GPA, low income -> APPROVED
('Tinashe Moyo',    2.50, 28000.00, 'PENDING'), -- Low GPA, high income -> REJECTED
('Kabwe Mutale',    3.10, 22000.00, 'PENDING'), -- Moderate GPA, high income -> REJECTED
('Naomi Sichone',   3.95, 19000.00, 'PENDING'), -- Top GPA, moderate income -> APPROVED
('Daniel Kasonde',  2.20, 9000.00,  'PENDING'); -- Low GPA, low income -> REJECTED

-- (b) Function: fn_eligibility_score
CREATE OR REPLACE FUNCTION fn_eligibility_score(p_gpa NUMERIC, p_income NUMERIC)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_gpa_points NUMERIC;
    v_income_points NUMERIC;
    v_total INT;
BEGIN
    IF p_gpa IS NULL OR p_gpa < 0.00 OR p_gpa > 4.00 THEN
        RAISE EXCEPTION 'Invalid GPA (%): must be between 0.00 and 4.00.', p_gpa;
    END IF;

    IF p_income IS NULL OR p_income < 0 THEN
        RAISE EXCEPTION 'Invalid household income (%): must be non-negative.', p_income;
    END IF;

    -- Academic merit component: up to 60 points (scaled from 4.00 GPA)
    v_gpa_points := (p_gpa / 4.00) * 60.0;

    -- Financial need component: up to 40 points (full 40 if income <= 10,000; 0 if >= 30,000)
    IF p_income <= 10000 THEN
        v_income_points := 40.0;
    ELSIF p_income >= 30000 THEN
        v_income_points := 0.0;
    ELSE
        v_income_points := ((30000.0 - p_income) / 20000.0) * 40.0;
    END IF;

    v_total := LEAST(100, GREATEST(0, ROUND(v_gpa_points + v_income_points)::INT));
    RETURN v_total;
END;
$$;

-- (c) Procedure: pr_assess_application
CREATE OR REPLACE PROCEDURE pr_assess_application(
    p_application_id INT,
    p_assessed_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_gpa NUMERIC(3, 2);
    v_income NUMERIC(12, 2);
    v_status VARCHAR(15);
    v_score INT;
    v_new_status VARCHAR(15);
BEGIN
    IF p_assessed_on IS NULL THEN
        RAISE EXCEPTION 'Assessment date cannot be NULL.';
    END IF;

    SELECT gpa, household_income, status INTO v_gpa, v_income, v_status
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application ID: %', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application ID % has already been assessed (status: %).',
            p_application_id, v_status;
    END IF;

    v_score := fn_eligibility_score(v_gpa, v_income);

    IF v_score >= 65 THEN
        v_new_status := 'APPROVED';
    ELSE
        v_new_status := 'REJECTED';
    END IF;

    INSERT INTO assessments (application_id, score, assessed_on)
    VALUES (p_application_id, v_score, p_assessed_on);

    UPDATE applications
    SET status = v_new_status
    WHERE application_id = p_application_id;
END;
$$;

-- (d) Trigger: Audit status changes on applications
CREATE OR REPLACE FUNCTION fn_audit_application_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO status_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_status_audit
AFTER UPDATE ON applications
FOR EACH ROW
EXECUTE FUNCTION fn_audit_application_status();

-- Assess all 6 applications through the procedure (triggers status_audit automatically)
CALL pr_assess_application(1, '2026-11-20');
CALL pr_assess_application(2, '2026-11-20');
CALL pr_assess_application(3, '2026-11-21');
CALL pr_assess_application(4, '2026-11-21');
CALL pr_assess_application(5, '2026-11-22');
CALL pr_assess_application(6, '2026-11-22');

-- (e) View: v_approved_scholarships
CREATE OR REPLACE VIEW v_approved_scholarships AS
SELECT
    a.application_id,
    a.applicant_name,
    a.gpa,
    a.household_income,
    s.score,
    s.assessed_on
FROM applications a
JOIN assessments s ON a.application_id = s.application_id
WHERE a.status = 'APPROVED';

SELECT * FROM v_approved_scholarships;

-- (f) Index and EXPLAIN
-- Justification: A composite B-tree index on (status, gpa DESC) supports filtering by
-- application status while returning top-ranked GPA applicants in pre-sorted order.
CREATE INDEX idx_applications_status_gpa ON applications (status, gpa DESC);

EXPLAIN ANALYZE
SELECT * FROM applications
WHERE status = 'APPROVED'
ORDER BY gpa DESC;

-- (g) Scheduled Job: pr_refresh_scholarships
CREATE OR REPLACE PROCEDURE pr_refresh_scholarships(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_assessed INT;
    v_approved INT;
    v_rejected INT;
BEGIN
    SELECT
        COUNT(s.assessment_id),
        COUNT(*) FILTER (WHERE a.status = 'APPROVED'),
        COUNT(*) FILTER (WHERE a.status = 'REJECTED')
    INTO v_assessed, v_approved, v_rejected
    FROM assessments s
    JOIN applications a ON s.application_id = a.application_id
    WHERE s.assessed_on = p_day;

    INSERT INTO scholarship_summary (summary_date, assessed_count, approved_count, rejected_count)
    VALUES (p_day, v_assessed, v_approved, v_rejected)
    ON CONFLICT (summary_date)
    DO UPDATE SET
        assessed_count = EXCLUDED.assessed_count,
        approved_count = EXCLUDED.approved_count,
        rejected_count = EXCLUDED.rejected_count;
END;
$$;

-- Schedule daily at 01:30 for the previous day
SELECT cron.schedule(
    'q10_refresh_scholarship_summary',
    '30 1 * * *',
    $$CALL pr_refresh_scholarships(CURRENT_DATE - INTERVAL '1 day');$$
);
