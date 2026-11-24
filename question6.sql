ICT371 Advanced Database - Question 6: Utility Billing and Meter Readings
-- DBMS: PostgreSQL

DROP TABLE IF EXISTS billing_summary, bills, meter_readings, customers CASCADE;

-- (a) Database and Seed Data
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    account_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE meter_readings (
    reading_id SERIAL PRIMARY KEY,
    customer_id INT NOT NULL REFERENCES customers(customer_id),
    reading_date DATE NOT NULL,
    reading_value NUMERIC(12, 2) NOT NULL CHECK (reading_value >= 0)
);

CREATE TABLE bills (
    bill_id SERIAL PRIMARY KEY,
    customer_id INT NOT NULL REFERENCES customers(customer_id),
    reading_id INT UNIQUE NOT NULL REFERENCES meter_readings(reading_id),
    units_used NUMERIC(12, 2) NOT NULL CHECK (units_used >= 0),
    amount_due NUMERIC(12, 2) NOT NULL CHECK (amount_due >= 0),
    status VARCHAR(10) NOT NULL DEFAULT 'UNPAID' CHECK (status IN ('UNPAID', 'PAID'))
);

CREATE TABLE billing_summary (
    summary_date DATE PRIMARY KEY,
    bill_count INT NOT NULL DEFAULT 0,
    total_units NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    total_amount NUMERIC(12, 2) NOT NULL DEFAULT 0.00
);

INSERT INTO customers (account_number, full_name) VALUES
('ACC-1001', 'Mwansa Chileshe'),
('ACC-1002', 'Natasha Mubita'),
('ACC-1003', 'Patrick Sichilima');

-- (b) Function: fn_compute_bill
CREATE OR REPLACE FUNCTION fn_compute_bill(p_units NUMERIC)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_amount NUMERIC(12, 2);
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Units consumed cannot be negative.';
    END IF;

    IF p_units <= 50 THEN
        v_amount := p_units * 1.50;
    ELSE
        v_amount := (50 * 1.50) + ((p_units - 50) * 2.20);
    END IF;

    RETURN ROUND(v_amount, 2);
END;
$$;

-- (c) Procedure: pr_record_reading
CREATE OR REPLACE PROCEDURE pr_record_reading(
    p_customer_id INT,
    p_reading_date DATE,
    p_reading_value NUMERIC(12, 2)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_last_date DATE;
    v_last_value NUMERIC(12, 2);
BEGIN
    PERFORM 1 FROM customers WHERE customer_id = p_customer_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown customer ID: %', p_customer_id;
    END IF;

    IF p_reading_date IS NULL THEN
        RAISE EXCEPTION 'Reading date cannot be NULL.';
    END IF;

    IF p_reading_value IS NULL OR p_reading_value < 0 THEN
        RAISE EXCEPTION 'Reading value must be non-negative.';
    END IF;

    SELECT reading_date, reading_value INTO v_last_date, v_last_value
    FROM meter_readings
    WHERE customer_id = p_customer_id
    ORDER BY reading_date DESC, reading_id DESC
    LIMIT 1;

    IF FOUND THEN
        IF p_reading_date <= v_last_date THEN
            RAISE EXCEPTION 'Reading date (%) must be strictly later than previous reading date (%).',
                p_reading_date, v_last_date;
        END IF;
        IF p_reading_value < v_last_value THEN
            RAISE EXCEPTION 'Reading value (%) cannot be lower than previous reading (%).',
                p_reading_value, v_last_value;
        END IF;
    END IF;

    INSERT INTO meter_readings (customer_id, reading_date, reading_value)
    VALUES (p_customer_id, p_reading_date, p_reading_value);
END;
$$;

-- (d) Trigger: Automatically generate bill after INSERT on meter_readings
CREATE OR REPLACE FUNCTION fn_generate_bill_on_reading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev_value NUMERIC(12, 2);
    v_units NUMERIC(12, 2);
    v_amount NUMERIC(12, 2);
BEGIN
    SELECT reading_value INTO v_prev_value
    FROM meter_readings
    WHERE customer_id = NEW.customer_id
      AND reading_id <> NEW.reading_id
    ORDER BY reading_date DESC, reading_id DESC
    LIMIT 1;

    IF NOT FOUND THEN
        v_units := NEW.reading_value;
    ELSE
        v_units := NEW.reading_value - v_prev_value;
    END IF;

    v_amount := fn_compute_bill(v_units);

    INSERT INTO bills (customer_id, reading_id, units_used, amount_due, status)
    VALUES (NEW.customer_id, NEW.reading_id, v_units, v_amount, 'UNPAID');

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_meter_readings_after_insert
AFTER INSERT ON meter_readings
FOR EACH ROW
EXECUTE FUNCTION fn_generate_bill_on_reading();

-- Load 6 valid readings across the 3 customers (bills generate automatically via trigger)
CALL pr_record_reading(1, '2026-10-25', 40.00);
CALL pr_record_reading(1, '2026-11-22', 110.00); -- 70 units used
CALL pr_record_reading(2, '2026-10-25', 30.00);
CALL pr_record_reading(2, '2026-11-22', 75.00);  -- 45 units used
CALL pr_record_reading(3, '2026-10-25', 60.00);
CALL pr_record_reading(3, '2026-11-22', 140.00); -- 80 units used

-- Mark 2 bills as PAID so v_unpaid_bills shows active unpaid vs paid separation
UPDATE bills SET status = 'PAID' WHERE bill_id IN (1, 3);

-- (e) View: v_unpaid_bills
CREATE OR REPLACE VIEW v_unpaid_bills AS
SELECT
    c.account_number,
    c.full_name,
    mr.reading_date,
    b.units_used,
    b.amount_due
FROM bills b
JOIN customers c ON b.customer_id = c.customer_id
JOIN meter_readings mr ON b.reading_id = mr.reading_id
WHERE b.status = 'UNPAID';

SELECT * FROM v_unpaid_bills;

-- (f) Index and EXPLAIN
-- Justification: A composite B-tree index on (customer_id, reading_date) allows fast
-- per-customer history lookups and chronological sorting without a full table scan.
CREATE INDEX idx_readings_customer_date ON meter_readings (customer_id, reading_date);

EXPLAIN ANALYZE
SELECT * FROM meter_readings
WHERE customer_id = 1
  AND reading_date BETWEEN '2026-10-01' AND '2026-11-30';

-- (g) Scheduled Job: pr_refresh_billing
CREATE OR REPLACE PROCEDURE pr_refresh_billing(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INT;
    v_units NUMERIC(12, 2);
    v_amount NUMERIC(12, 2);
BEGIN
    SELECT COUNT(b.bill_id), COALESCE(SUM(b.units_used), 0.00), COALESCE(SUM(b.amount_due), 0.00)
    INTO v_count, v_units, v_amount
    FROM bills b
    JOIN meter_readings mr ON b.reading_id = mr.reading_id
    WHERE mr.reading_date = p_day;

    INSERT INTO billing_summary (summary_date, bill_count, total_units, total_amount)
    VALUES (p_day, v_count, v_units, v_amount)
    ON CONFLICT (summary_date)
    DO UPDATE SET
        bill_count = EXCLUDED.bill_count,
        total_units = EXCLUDED.total_units,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- Schedule daily at 01:15 for the previous day
SELECT cron.schedule(
    'q6_refresh_billing_summary',
    '15 1 * * *',
    $$CALL pr_refresh_billing(CURRENT_DATE - INTERVAL '1 day');$$
);
