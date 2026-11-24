 ICT371 Advanced Database - Question 7: Fuel Station Pump Sales
-- DBMS: PostgreSQL

DROP TABLE IF EXISTS fuel_daily_summary, tank_audit, fuel_sales, tanks CASCADE;

-- (a) Database and Seed Data
CREATE TABLE tanks (
    tank_id SERIAL PRIMARY KEY,
    fuel_type VARCHAR(30) UNIQUE NOT NULL,
    unit_price NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    current_litres NUMERIC(12, 2) NOT NULL CHECK (current_litres >= 0)
);

CREATE TABLE fuel_sales (
    sale_id SERIAL PRIMARY KEY,
    tank_id INT NOT NULL REFERENCES tanks(tank_id),
    litres NUMERIC(10, 2) NOT NULL CHECK (litres > 0),
    unit_price NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    sold_on DATE NOT NULL
);

CREATE TABLE tank_audit (
    audit_id SERIAL PRIMARY KEY,
    tank_id INT NOT NULL REFERENCES tanks(tank_id),
    old_litres NUMERIC(12, 2) NOT NULL,
    new_litres NUMERIC(12, 2) NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE fuel_daily_summary (
    sales_date DATE PRIMARY KEY,
    total_litres NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    total_revenue NUMERIC(12, 2) NOT NULL DEFAULT 0.00
);

INSERT INTO tanks (fuel_type, unit_price, current_litres) VALUES
('Petrol',   29.92, 1500.00),
('Diesel',   26.96, 600.00),  -- Will drop below 500L after sales
('Kerosene', 20.44, 800.00);

-- (b) Function: fn_fuel_cost
CREATE OR REPLACE FUNCTION fn_fuel_cost(p_tank_id INT, p_litres NUMERIC)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10, 2);
BEGIN
    IF p_litres IS NULL OR p_litres <= 0 THEN
        RAISE EXCEPTION 'Litres must be strictly positive.';
    END IF;

    SELECT unit_price INTO v_price
    FROM tanks
    WHERE tank_id = p_tank_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown tank ID: %', p_tank_id;
    END IF;

    RETURN ROUND(v_price * p_litres, 2);
END;
$$;

-- (c) Procedure: pr_record_fuel_sale
CREATE OR REPLACE PROCEDURE pr_record_fuel_sale(
    p_tank_id INT,
    p_litres NUMERIC(10, 2),
    p_sold_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10, 2);
    v_avail NUMERIC(12, 2);
    v_cost NUMERIC(12, 2);
BEGIN
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date cannot be NULL.';
    END IF;

    -- Validate tank and positive litres
    v_cost := fn_fuel_cost(p_tank_id, p_litres);

    -- Lock tank row to prevent negative stock under concurrent sales
    SELECT unit_price, current_litres INTO v_price, v_avail
    FROM tanks
    WHERE tank_id = p_tank_id
    FOR UPDATE;

    IF v_avail < p_litres THEN
        RAISE EXCEPTION 'Insufficient fuel in tank %. Available: % L, Requested: % L',
            p_tank_id, v_avail, p_litres;
    END IF;

    INSERT INTO fuel_sales (tank_id, litres, unit_price, sold_on)
    VALUES (p_tank_id, p_litres, v_price, p_sold_on);

    UPDATE tanks
    SET current_litres = current_litres - p_litres
    WHERE tank_id = p_tank_id;
END;
$$;

-- (d) Trigger: Audit changes to current_litres
CREATE OR REPLACE FUNCTION fn_audit_tank_litres()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.current_litres IS DISTINCT FROM NEW.current_litres THEN
        INSERT INTO tank_audit (tank_id, old_litres, new_litres, changed_at)
        VALUES (NEW.tank_id, OLD.current_litres, NEW.current_litres, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tanks_litres_audit
AFTER UPDATE ON tanks
FOR EACH ROW
EXECUTE FUNCTION fn_audit_tank_litres();

-- Load 6 valid fuel sales through the procedure (triggers tank_audit automatically)
CALL pr_record_fuel_sale(1, 45.00,  '2026-11-20');
CALL pr_record_fuel_sale(2, 120.00, '2026-11-20'); -- Diesel drops to 480L (< 500L)
CALL pr_record_fuel_sale(3, 30.00,  '2026-11-21');
CALL pr_record_fuel_sale(1, 60.50,  '2026-11-21');
CALL pr_record_fuel_sale(2, 50.00,  '2026-11-22');
CALL pr_record_fuel_sale(3, 25.00,  '2026-11-22');

-- (e) View: v_low_tanks
CREATE OR REPLACE VIEW v_low_tanks AS
SELECT tank_id, fuel_type, unit_price, current_litres
FROM tanks
WHERE current_litres < 500.00;

SELECT * FROM v_low_tanks;

-- (f) Index and EXPLAIN
-- Justification: A composite B-tree index on (tank_id, sold_on) optimizes queries
-- filtering by a specific fuel tank across a date interval.
CREATE INDEX idx_fuel_sales_tank_date ON fuel_sales (tank_id, sold_on);

EXPLAIN ANALYZE
SELECT * FROM fuel_sales
WHERE tank_id = 1
  AND sold_on BETWEEN '2026-11-01' AND '2026-11-30';

-- (g) Scheduled Job: pr_refresh_fuel_summary
CREATE OR REPLACE PROCEDURE pr_refresh_fuel_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_litres NUMERIC(12, 2);
    v_revenue NUMERIC(12, 2);
BEGIN
    SELECT COALESCE(SUM(litres), 0.00), COALESCE(SUM(litres * unit_price), 0.00)
    INTO v_litres, v_revenue
    FROM fuel_sales
    WHERE sold_on = p_day;

    INSERT INTO fuel_daily_summary (sales_date, total_litres, total_revenue)
    VALUES (p_day, v_litres, v_revenue)
    ON CONFLICT (sales_date)
    DO UPDATE SET
        total_litres = EXCLUDED.total_litres,
        total_revenue = EXCLUDED.total_revenue;
END;
$$;

-- Schedule daily at 00:45 for the previous day
SELECT cron.schedule(
    'q7_refresh_fuel_summary',
    '45 0 * * *',
    $$CALL pr_refresh_fuel_summary(CURRENT_DATE - INTERVAL '1 day');$$
);
