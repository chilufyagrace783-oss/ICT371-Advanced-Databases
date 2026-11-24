ICT371 Advanced Database - Question 5: Warehouse stock transfer

  DROP TABLE IF EXISTS transfer_summary, transfer_audit, stock_transfers, warehouse_stock, items, warehouses CASCADE;

-- (a) Database and Seed Data
CREATE TABLE warehouses (
    warehouse_id SERIAL PRIMARY KEY,
    warehouse_name VARCHAR(100) NOT NULL
);

CREATE TABLE items (
    item_id SERIAL PRIMARY KEY,
    item_name VARCHAR(100) NOT NULL
);

CREATE TABLE warehouse_stock (
    warehouse_id INT NOT NULL REFERENCES warehouses(warehouse_id),
    item_id INT NOT NULL REFERENCES items(item_id),
    quantity INT NOT NULL CHECK (quantity >= 0),
    PRIMARY KEY (warehouse_id, item_id)
);

CREATE TABLE stock_transfers (
    transfer_id SERIAL PRIMARY KEY,
    from_warehouse_id INT NOT NULL REFERENCES warehouses(warehouse_id),
    to_warehouse_id INT NOT NULL REFERENCES warehouses(warehouse_id),
    item_id INT NOT NULL REFERENCES items(item_id),
    quantity INT NOT NULL CHECK (quantity > 0),
    transferred_on DATE NOT NULL,
    CHECK (from_warehouse_id <> to_warehouse_id)
);

CREATE TABLE transfer_audit (
    audit_id SERIAL PRIMARY KEY,
    transfer_id INT NOT NULL REFERENCES stock_transfers(transfer_id),
    item_id INT NOT NULL REFERENCES items(item_id),
    quantity INT NOT NULL,
    logged_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE transfer_summary (
    summary_date DATE PRIMARY KEY,
    transfer_count INT NOT NULL DEFAULT 0,
    total_units INT NOT NULL DEFAULT 0
);

INSERT INTO warehouses (warehouse_name) VALUES
('Lusaka Central Hub'),
('Ndola Copperbelt Depot'),
('Kapiri Mposhi Transit Store');

INSERT INTO items (item_name) VALUES
('50kg Maize Meal Bag'),
('20L Cooking Oil Jerrycan'),
('50kg Cement Bag');

-- Seed initial stock balances (leaving some pairs below threshold 15 for the view)
INSERT INTO warehouse_stock (warehouse_id, item_id, quantity) VALUES
(1, 1, 100),
(1, 2, 40),
(1, 3, 80),
(2, 1, 10), -- Below 15
(2, 2, 25),
(3, 1, 5),  -- Below 15
(3, 3, 12); -- Below 15

-- (b) Function: fn_available_stock
CREATE OR REPLACE FUNCTION fn_available_stock(p_warehouse_id INT, p_item_id INT)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_qty INT;
BEGIN
    PERFORM 1 FROM warehouses WHERE warehouse_id = p_warehouse_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown warehouse ID: %', p_warehouse_id;
    END IF;

    PERFORM 1 FROM items WHERE item_id = p_item_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown item ID: %', p_item_id;
    END IF;

    SELECT quantity INTO v_qty
    FROM warehouse_stock
    WHERE warehouse_id = p_warehouse_id
      AND item_id = p_item_id;

    RETURN COALESCE(v_qty, 0);
END;
$$;

-- (c) Procedure: pr_transfer_stock
CREATE OR REPLACE PROCEDURE pr_transfer_stock(
    p_from_warehouse_id INT,
    p_to_warehouse_id INT,
    p_item_id INT,
    p_quantity INT,
    p_transferred_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_avail INT;
BEGIN
    IF p_from_warehouse_id = p_to_warehouse_id THEN
        RAISE EXCEPTION 'Source and destination warehouses must be different.';
    END IF;

    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Transfer quantity must be strictly positive.';
    END IF;

    IF p_transferred_on IS NULL THEN
        RAISE EXCEPTION 'Transfer date cannot be NULL.';
    END IF;

    -- Validate warehouses and item, and lock source stock row
    v_avail := fn_available_stock(p_from_warehouse_id, p_item_id);
    PERFORM fn_available_stock(p_to_warehouse_id, p_item_id);

    PERFORM 1 FROM warehouse_stock
    WHERE warehouse_id = p_from_warehouse_id AND item_id = p_item_id
    FOR UPDATE;

    -- Re-check after lock
    v_avail := fn_available_stock(p_from_warehouse_id, p_item_id);
    IF v_avail < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock at warehouse %. Available: %, Requested: %',
            p_from_warehouse_id, v_avail, p_quantity;
    END IF;

    -- Deduct from source
    UPDATE warehouse_stock
    SET quantity = quantity - p_quantity
    WHERE warehouse_id = p_from_warehouse_id
      AND item_id = p_item_id;

    -- Add to destination (upsert in case item was not yet stocked there)
    INSERT INTO warehouse_stock (warehouse_id, item_id, quantity)
    VALUES (p_to_warehouse_id, p_item_id, p_quantity)
    ON CONFLICT (warehouse_id, item_id)
    DO UPDATE SET quantity = warehouse_stock.quantity + EXCLUDED.quantity;

    -- Record transfer
    INSERT INTO stock_transfers (from_warehouse_id, to_warehouse_id, item_id, quantity, transferred_on)
    VALUES (p_from_warehouse_id, p_to_warehouse_id, p_item_id, p_quantity, p_transferred_on);
END;
$$;

-- (d) Trigger: Audit after INSERT on stock_transfers
CREATE OR REPLACE FUNCTION fn_audit_stock_transfer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO transfer_audit (transfer_id, item_id, quantity, logged_at)
    VALUES (NEW.transfer_id, NEW.item_id, NEW.quantity, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_stock_transfers_audit
AFTER INSERT ON stock_transfers
FOR EACH ROW
EXECUTE FUNCTION fn_audit_stock_transfer();

-- Load 6 valid transfers through the procedure
CALL pr_transfer_stock(1, 2, 1, 10, '2026-11-20');
CALL pr_transfer_stock(1, 3, 2, 8,  '2026-11-20');
CALL pr_transfer_stock(1, 2, 3, 15, '2026-11-21');
CALL pr_transfer_stock(2, 3, 2, 5,  '2026-11-21');
CALL pr_transfer_stock(1, 3, 1, 4,  '2026-11-22');
CALL pr_transfer_stock(3, 2, 3, 2,  '2026-11-22');

-- (e) View: v_low_warehouse_stock
CREATE OR REPLACE VIEW v_low_warehouse_stock AS
SELECT
    w.warehouse_name,
    i.item_name,
    ws.quantity
FROM warehouse_stock ws
JOIN warehouses w ON ws.warehouse_id = w.warehouse_id
JOIN items i ON ws.item_id = i.item_id
WHERE ws.quantity < 15;

SELECT * FROM v_low_warehouse_stock;

-- (f) Index and EXPLAIN
-- Justification: A composite B-tree index on (item_id, transferred_on) matches equality
-- filtering on item_id followed by a range scan on transferred_on.
CREATE INDEX idx_transfers_item_date ON stock_transfers (item_id, transferred_on);

EXPLAIN ANALYZE
SELECT * FROM stock_transfers
WHERE item_id = 1
  AND transferred_on BETWEEN '2026-11-01' AND '2026-11-30';

-- (g) Scheduled Job: pr_refresh_transfers
CREATE OR REPLACE PROCEDURE pr_refresh_transfers(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INT;
    v_units INT;
BEGIN
    SELECT COUNT(*), COALESCE(SUM(quantity), 0)
    INTO v_count, v_units
    FROM stock_transfers
    WHERE transferred_on = p_day;

    INSERT INTO transfer_summary (summary_date, transfer_count, total_units)
    VALUES (p_day, v_count, v_units)
    ON CONFLICT (summary_date)
    DO UPDATE SET
        transfer_count = EXCLUDED.transfer_count,
        total_units = EXCLUDED.total_units;
END;
$$;

-- Schedule daily at 00:30 for the previous day
SELECT cron.schedule(
    'q5_refresh_transfers',
    '30 0 * * *',
    $$CALL pr_refresh_transfers(CURRENT_DATE - INTERVAL '1 day');$$
);
