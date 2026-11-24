ICT371 Advanced Database - Question 1: Pharmacy Stock and Daily Sales
 DBMS: PostgreSQL

DROP TABLE IF EXISTS daily_sales, stock_audit, sales, medicines CASCADE;

-- (a) Database and Seed Data
CREATE TABLE medicines (
    medicine_id SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    stock_qty INT NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id SERIAL PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
    quantity INT NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    sold_on DATE NOT NULL
);

CREATE TABLE stock_audit (
    audit_id SERIAL PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
    old_qty INT NOT NULL,
    new_qty INT NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_sales (
    sales_date DATE PRIMARY KEY,
    total_qty INT NOT NULL DEFAULT 0,
    total_amount NUMERIC(12, 2) NOT NULL DEFAULT 0.00
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
('Paracetamol 500mg', 15.00, 50),
('Amoxicillin 250mg', 45.50, 20),
('Ibuprofen 400mg', 25.00, 12);

-- (b) Function: fn_sale_value
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10, 2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: must be positive.';
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine ID: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

-- (c) Procedure: pr_record_sale
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INT,
    p_quantity INT,
    p_sold_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10, 2);
    v_stock INT;
    v_total NUMERIC(12, 2);
BEGIN
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date cannot be NULL.';
    END IF;

    -- Validate medicine and quantity
    v_total := fn_sale_value(p_medicine_id, p_quantity);

    -- Lock row to prevent overselling
    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock. Available: %, Requested: %', v_stock, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- (d) Trigger: Stock Audit
CREATE OR REPLACE FUNCTION fn_audit_medicine_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.stock_qty IS DISTINCT FROM NEW.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
EXECUTE FUNCTION fn_audit_medicine_stock();

-- Load 6 valid sales through the completed procedure (triggers audit automatically)
CALL pr_record_sale(1, 5, '2026-11-20');
CALL pr_record_sale(2, 2, '2026-11-20');
CALL pr_record_sale(3, 4, '2026-11-21'); -- Drops Ibuprofen stock to 8 (< 10)
CALL pr_record_sale(1, 10, '2026-11-21');
CALL pr_record_sale(2, 3, '2026-11-22');
CALL pr_record_sale(3, 1, '2026-11-22');

-- (e) View: v_low_stock
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty
FROM medicines
WHERE stock_qty < 10;

SELECT * FROM v_low_stock;

-- (f) Index and EXPLAIN
-- Justification: A composite B-tree index on (medicine_id, sold_on) supports an exact
-- equality match on medicine_id followed immediately by an ordered range scan on sold_on.
CREATE INDEX idx_sales_med_date ON sales (medicine_id, sold_on);

EXPLAIN ANALYZE
SELECT * FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN '2026-11-01' AND '2026-11-30';

-- (g) Scheduled Job: pr_refresh_sales
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_qty INT;
    v_total_amount NUMERIC(12, 2);
BEGIN
    SELECT COALESCE(SUM(quantity), 0), COALESCE(SUM(quantity * unit_price), 0.00)
    INTO v_total_qty, v_total_amount
    FROM sales
    WHERE sold_on = p_day;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    VALUES (p_day, v_total_qty, v_total_amount)
    ON CONFLICT (sales_date)
    DO UPDATE SET
        total_qty = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- Schedule daily at 00:15 for the previous day (requires pg_cron)
SELECT cron.schedule(
    'q1_refresh_daily_sales',
    '15 0 * * *',
    $$CALL pr_refresh_sales(CURRENT_DATE - INTERVAL '1 day');$$
);
