ICT371 Advanced Database - Question 3: Library Returns and Overdue Fines
   DBMS: PostgreSQL

DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

-- (a) Database and Seed Data
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id SERIAL PRIMARY KEY,
    book_id INT NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on DATE NOT NULL,
    due_on DATE NOT NULL CHECK (due_on >= borrowed_on),
    returned_on DATE NULL CHECK (returned_on IS NULL OR returned_on >= borrowed_on),
    fine_amount NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (fine_amount >= 0)
);

CREATE TABLE loan_audit (
    audit_id SERIAL PRIMARY KEY,
    loan_id INT NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE NULL,
    new_returned_on DATE NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL DEFAULT 0,
    total_fine NUMERIC(12, 2) NOT NULL DEFAULT 0.00
);

INSERT INTO books (title) VALUES
('Database System Concepts'),
('Designing Data-Intensive Applications'),
('PostgreSQL: Up and Running');

-- Six loans covering open overdue, on-time, and returned loans
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
(1, 'Kelvin Banda',   CURRENT_DATE - 15, CURRENT_DATE - 5, NULL, 0.00),             -- Open overdue
(2, 'Grace Phiri',    CURRENT_DATE - 10, CURRENT_DATE - 2, NULL, 0.00),             -- Open overdue
(3, 'Peter Tembo',    CURRENT_DATE - 3,  CURRENT_DATE + 7, NULL, 0.00),             -- Open on-time
(1, 'Mary Mulenga',   CURRENT_DATE - 20, CURRENT_DATE - 10, CURRENT_DATE - 12, 0.00), -- Returned early
(2, 'John Lungu',     CURRENT_DATE - 18, CURRENT_DATE - 10, CURRENT_DATE - 10, 0.00), -- Returned on due date
(3, 'Esther Sakala',  CURRENT_DATE - 25, CURRENT_DATE - 15, CURRENT_DATE - 11, 8.00); -- Returned 4 days late (K8)

-- (b) Function: fn_loan_fine
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due_on DATE;
    v_returned_on DATE;
    v_effective_end DATE;
    v_overdue_days INT;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'Evaluation date (p_as_of) cannot be NULL.';
    END IF;

    SELECT due_on, returned_on INTO v_due_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan ID: %', p_loan_id;
    END IF;

    IF v_returned_on IS NOT NULL THEN
        v_effective_end := LEAST(p_as_of, v_returned_on);
    ELSE
        v_effective_end := p_as_of;
    END IF;

    v_overdue_days := GREATEST(0, v_effective_end - v_due_on);
    RETURN (v_overdue_days * 2.00)::NUMERIC(10, 2);
END;
$$;

-- (c) Procedure: pr_return_loan
CREATE OR REPLACE PROCEDURE pr_return_loan(
    p_loan_id INT,
    p_returned_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed_on DATE;
    v_existing_return DATE;
    v_final_fine NUMERIC(10, 2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date cannot be NULL.';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed_on, v_existing_return
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan ID: %', p_loan_id;
    END IF;

    IF v_existing_return IS NOT NULL THEN
        RAISE EXCEPTION 'Loan ID % has already been returned on %.', p_loan_id, v_existing_return;
    END IF;

    IF p_returned_on < v_borrowed_on THEN
        RAISE EXCEPTION 'Return date (%) cannot be before borrowed date (%).', p_returned_on, v_borrowed_on;
    END IF;

    v_final_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_final_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- (d) Trigger: Audit changes to returned_on
CREATE OR REPLACE FUNCTION fn_audit_loan_return()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.returned_on IS DISTINCT FROM NEW.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_return_audit
AFTER UPDATE ON loans
FOR EACH ROW
EXECUTE FUNCTION fn_audit_loan_return();

-- (e) View: v_overdue_loans
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    b.title,
    l.borrower_name,
    l.due_on,
    fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON l.book_id = b.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- (f) Index and EXPLAIN
-- Justification: A partial composite index on (book_id) WHERE returned_on IS NULL
-- isolates only active unreturned loans, keeping the index compact and fast.
CREATE INDEX idx_loans_unreturned_book ON loans (book_id) WHERE returned_on IS NULL;

EXPLAIN ANALYZE
SELECT * FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;

-- (g) Scheduled Job: pr_refresh_overdue
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INT;
    v_total_fine NUMERIC(12, 2);
BEGIN
    SELECT COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0.00)
    INTO v_count, v_total_fine
    FROM loans
    WHERE returned_on IS NULL OR returned_on > p_as_of;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    VALUES (p_as_of, v_count, v_total_fine)
    ON CONFLICT (snapshot_date)
    DO UPDATE SET
        overdue_count = EXCLUDED.overdue_count,
        total_fine = EXCLUDED.total_fine;
END;
$$;

-- Schedule daily at 00:10 for CURRENT_DATE
SELECT cron.schedule(
    'q3_refresh_overdue_summary',
    '10 0 * * *',
    $$CALL pr_refresh_overdue(CURRENT_DATE);$$
);
