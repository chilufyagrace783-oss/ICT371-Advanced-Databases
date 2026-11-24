ICT371 Advanced Database - Question 9: Vehicle Fleet Maintenance
-- DBMS: PostgreSQL

DROP TABLE IF EXISTS maintenance_summary, service_audit, service_records, vehicles CASCADE;

-- (a) Database and Seed Data
CREATE TABLE vehicles (
    vehicle_id SERIAL PRIMARY KEY,
    reg_number VARCHAR(20) UNIQUE NOT NULL,
    current_odometer INT NOT NULL CHECK (current_odometer >= 0),
    next_service_km INT NOT NULL CHECK (next_service_km >= 0)
);

CREATE TABLE service_records (
    service_id SERIAL PRIMARY KEY,
    vehicle_id INT NOT NULL REFERENCES vehicles(vehicle_id),
    odometer_km INT NOT NULL CHECK (odometer_km >= 0),
    cost NUMERIC(12, 2) NOT NULL CHECK (cost > 0),
    serviced_on DATE NOT NULL
);

CREATE TABLE service_audit (
    audit_id SERIAL PRIMARY KEY,
    vehicle_id INT NOT NULL REFERENCES vehicles(vehicle_id),
    old_odometer INT NOT NULL,
    new_odometer INT NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE maintenance_summary (
    summary_date DATE PRIMARY KEY,
    service_count INT NOT NULL DEFAULT 0,
    total_cost NUMERIC(12, 2) NOT NULL DEFAULT 0.00
);

-- Three vehicles (Vehicle 3 is due/overdue for service with >= 0 km overdue)
INSERT INTO vehicles (reg_number, current_odometer, next_service_km) VALUES
('BAA 4512', 42000, 45000),
('BCD 7890', 88500, 90000),
('CAE 1123', 61200, 60000); -- Already due for service (1200 km overdue)

-- (b) Function: fn_km_overdue
CREATE OR REPLACE FUNCTION fn_km_overdue(p_vehicle_id INT)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INT;
    v_next INT;
BEGIN
    SELECT current_odometer, next_service_km INTO v_current, v_next
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle ID: %', p_vehicle_id;
    END IF;

    RETURN GREATEST(0, v_current - v_next);
END;
$$;

-- (c) Procedure: pr_record_service
CREATE OR REPLACE PROCEDURE pr_record_service(
    p_vehicle_id INT,
    p_odometer_km INT,
    p_cost NUMERIC(12, 2),
    p_serviced_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr_odo INT;
BEGIN
    IF p_cost IS NULL OR p_cost <= 0 THEN
        RAISE EXCEPTION 'Service cost must be strictly positive.';
    END IF;

    IF p_serviced_on IS NULL THEN
        RAISE EXCEPTION 'Service date cannot be NULL.';
    END IF;

    SELECT current_odometer INTO v_curr_odo
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle ID: %', p_vehicle_id;
    END IF;

    IF p_odometer_km IS NULL OR p_odometer_km < v_curr_odo THEN
        RAISE EXCEPTION 'Odometer reading (% km) cannot be less than current vehicle odometer (% km).',
            p_odometer_km, v_curr_odo;
    END IF;

    INSERT INTO service_records (vehicle_id, odometer_km, cost, serviced_on)
    VALUES (p_vehicle_id, p_odometer_km, p_cost, p_serviced_on);

    UPDATE vehicles
    SET current_odometer = p_odometer_km,
        next_service_km = p_odometer_km + 5000
    WHERE vehicle_id = p_vehicle_id;
END;
$$;

-- (d) Trigger: Audit changes to current_odometer
CREATE OR REPLACE FUNCTION fn_audit_vehicle_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.current_odometer IS DISTINCT FROM NEW.current_odometer THEN
        INSERT INTO service_audit (vehicle_id, old_odometer, new_odometer, changed_at)
        VALUES (NEW.vehicle_id, OLD.current_odometer, NEW.current_odometer, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_vehicles_odometer_audit
AFTER UPDATE ON vehicles
FOR EACH ROW
EXECUTE FUNCTION fn_audit_vehicle_odometer();

-- Load 6 valid service records through the procedure (triggers service_audit automatically)
CALL pr_record_service(1, 45100, 1850.00, '2026-10-15');
CALL pr_record_service(1, 50200, 2100.00, '2026-11-18');
CALL pr_record_service(2, 90100, 3200.00, '2026-10-20');
CALL pr_record_service(2, 95300, 2950.00, '2026-11-19');
CALL pr_record_service(3, 61500, 2400.00, '2026-11-10');
CALL pr_record_service(3, 66500, 2600.00, '2026-11-21');

-- Simulate Vehicle 2 exceeding its next_service_km so v_service_due returns a row
UPDATE vehicles SET current_odometer = 101200 WHERE vehicle_id = 2;

-- (e) View: v_service_due
CREATE OR REPLACE VIEW v_service_due AS
SELECT
    vehicle_id,
    reg_number,
    current_odometer,
    next_service_km,
    fn_km_overdue(vehicle_id) AS km_overdue
FROM vehicles
WHERE current_odometer >= next_service_km;

SELECT * FROM v_service_due;

-- (f) Index and EXPLAIN
-- Justification: A composite B-tree index on (vehicle_id, serviced_on) allows fast
-- service history retrieval for a given vehicle over a date window.
CREATE INDEX idx_service_records_vehicle_date ON service_records (vehicle_id, serviced_on);

EXPLAIN ANALYZE
SELECT * FROM service_records
WHERE vehicle_id = 1
  AND serviced_on BETWEEN '2026-10-01' AND '2026-11-30';

-- (g) Scheduled Job: pr_refresh_maintenance
CREATE OR REPLACE PROCEDURE pr_refresh_maintenance(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INT;
    v_cost NUMERIC(12, 2);
BEGIN
    SELECT COUNT(*), COALESCE(SUM(cost), 0.00)
    INTO v_count, v_cost
    FROM service_records
    WHERE serviced_on = p_day;

    INSERT INTO maintenance_summary (summary_date, service_count, total_cost)
    VALUES (p_day, v_count, v_cost)
    ON CONFLICT (summary_date)
    DO UPDATE SET
        service_count = EXCLUDED.service_count,
        total_cost = EXCLUDED.total_cost;
END;
$$;

-- Schedule daily at 01:20 for the previous day
SELECT cron.schedule(
    'q9_refresh_maintenance_summary',
    '20 1 * * *',
    $$CALL pr_refresh_maintenance(CURRENT_DATE - INTERVAL '1 day');$$
);
