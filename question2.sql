ICT371 Advanced Database - Question 2: University Fee Payments
  DBMS: PostgreSQL


DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

-- (a) Database and Seed Data
CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL,
    fee_due NUMERIC(12, 2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    amount NUMERIC(12, 2) NOT NULL CHECK (amount > 0),
    paid_on DATE NOT NULL
);

CREATE TABLE payment_audit (
    audit_id SERIAL PRIMARY KEY,
    payment_id INT NOT NULL REFERENCES payments(payment_id),
    student_id INT NOT NULL REFERENCES students(student_id),
    amount NUMERIC(12, 2) NOT NULL,
    logged_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count INT NOT NULL DEFAULT 0,
    total_amount NUMERIC(12, 2) NOT NULL DEFAULT 0.00
);

-- Three students with different fee balances (Student 3 will have no payments)
INSERT INTO students (student_number, full_name, fee_due) VALUES
('STU2026001', 'Chanda Mwamba', 15000.00),
('STU2026002', 'Bwalya Mutale', 12000.00),
('STU2026003', 'Mutinta Zulu', 18000.00);

-- (b) Function: fn_fee_balance
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due NUMERIC(12, 2);
    v_total_paid NUMERIC(12, 2);
BEGIN
    SELECT fee_due INTO v_fee_due
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student ID: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0.00) INTO v_total_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee_due - v_total_paid;
END;
$$;

-- (c) Procedure: pr_receive_payment
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INT,
    p_amount NUMERIC(12, 2),
    p_paid_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12, 2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be strictly positive.';
    END IF;

    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date cannot be NULL.';
    END IF;

    -- Lock student row to serialize concurrent balance checks
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;

    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Overpayment rejected. Outstanding balance: %, Attempted: %', v_balance, p_amount;
    END IF;

    -- Insert valid payment without altering fee_due
    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- (d) Trigger: Payment Audit
CREATE OR REPLACE FUNCTION fn_log_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_after_insert
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION fn_log_payment_audit();

-- Load 6 valid payments across students 1 and 2 (Student 2 fully settles; Student 3 has 0 payments)
CALL pr_receive_payment(1, 5000.00, '2026-11-18');
CALL pr_receive_payment(1, 3000.00, '2026-11-19');
CALL pr_receive_payment(1, 2000.00, '2026-11-20');
CALL pr_receive_payment(2, 6000.00, '2026-11-18');
CALL pr_receive_payment(2, 4000.00, '2026-11-19');
CALL pr_receive_payment(2, 2000.00, '2026-11-20');

-- (e) View: v_fee_balances
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    fn_fee_balance(s.student_id) AS outstanding_balance
FROM students s
WHERE fn_fee_balance(s.student_id) > 0;

SELECT * FROM v_fee_balances;

-- (f) Index and EXPLAIN
-- Justification: Filtering by student_id (equality) and paid_on (date range) directly
-- matches a composite B-tree index ordered as (student_id, paid_on).
CREATE INDEX idx_payments_student_date ON payments (student_id, paid_on);

EXPLAIN ANALYZE
SELECT * FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN '2026-11-01' AND '2026-11-30';

-- (g) Scheduled Job: pr_refresh_collections
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INT;
    v_total NUMERIC(12, 2);
BEGIN
    SELECT COUNT(*), COALESCE(SUM(amount), 0.00)
    INTO v_count, v_total
    FROM payments
    WHERE paid_on = p_day;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    VALUES (p_day, v_count, v_total)
    ON CONFLICT (collection_date)
    DO UPDATE SET
        payment_count = EXCLUDED.payment_count,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- Schedule daily at 01:00 for the previous day
SELECT cron.schedule(
    'q2_refresh_daily_collections',
    '0 1 * * *',
    $$CALL pr_refresh_collections(CURRENT_DATE - INTERVAL '1 day');$$
);
