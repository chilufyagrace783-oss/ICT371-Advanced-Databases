ICT371 Advanced Database - Question 8: Event Ticket Reservations
-- DBMS: PostgreSQL

DROP TABLE IF EXISTS ticket_summary, ticket_audit, bookings, events CASCADE;

-- (a) Database and Seed Data
CREATE TABLE events (
    event_id SERIAL PRIMARY KEY,
    event_name VARCHAR(120) NOT NULL,
    event_date DATE NOT NULL,
    ticket_price NUMERIC(10, 2) NOT NULL CHECK (ticket_price > 0),
    seats_remaining INT NOT NULL CHECK (seats_remaining >= 0)
);

CREATE TABLE bookings (
    booking_id SERIAL PRIMARY KEY,
    event_id INT NOT NULL REFERENCES events(event_id),
    customer_name VARCHAR(100) NOT NULL,
    seat_count INT NOT NULL CHECK (seat_count > 0),
    total_amount NUMERIC(12, 2) NOT NULL CHECK (total_amount > 0),
    booked_on DATE NOT NULL
);

CREATE TABLE ticket_audit (
    audit_id SERIAL PRIMARY KEY,
    event_id INT NOT NULL REFERENCES events(event_id),
    old_seats INT NOT NULL,
    new_seats INT NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE ticket_summary (
    summary_date DATE PRIMARY KEY,
    booking_count INT NOT NULL DEFAULT 0,
    seats_sold INT NOT NULL DEFAULT 0,
    total_revenue NUMERIC(12, 2) NOT NULL DEFAULT 0.00
);

-- Three events (including upcoming and past/low-seat events)
INSERT INTO events (event_name, event_date, ticket_price, seats_remaining) VALUES
('Lusaka Tech & Innovation Summit', CURRENT_DATE + 10, 250.00, 120),
('Copperbelt Music & Arts Festival', CURRENT_DATE + 5,  150.00, 25), -- Will drop below 20
('Kapiri Mposhi Business Expo',     CURRENT_DATE - 3,  100.00, 10); -- Past event

-- (b) Function: fn_booking_total
CREATE OR REPLACE FUNCTION fn_booking_total(p_event_id INT, p_seat_count INT)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10, 2);
BEGIN
    IF p_seat_count IS NULL OR p_seat_count <= 0 THEN
        RAISE EXCEPTION 'Seat count must be strictly positive.';
    END IF;

    SELECT ticket_price INTO v_price
    FROM events
    WHERE event_id = p_event_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown event ID: %', p_event_id;
    END IF;

    RETURN ROUND(v_price * p_seat_count, 2);
END;
$$;

-- (c) Procedure: pr_book_tickets
CREATE OR REPLACE PROCEDURE pr_book_tickets(
    p_event_id INT,
    p_customer_name VARCHAR,
    p_seat_count INT,
    p_booked_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_event_date DATE;
    v_seats INT;
    v_total NUMERIC(12, 2);
BEGIN
    IF p_customer_name IS NULL OR TRIM(p_customer_name) = '' THEN
        RAISE EXCEPTION 'Customer name is required.';
    END IF;

    IF p_booked_on IS NULL THEN
        RAISE EXCEPTION 'Booking date cannot be NULL.';
    END IF;

    -- Validate event and positive seat count
    v_total := fn_booking_total(p_event_id, p_seat_count);

    -- Lock event row to prevent overbooking
    SELECT event_date, seats_remaining INTO v_event_date, v_seats
    FROM events
    WHERE event_id = p_event_id
    FOR UPDATE;

    IF p_booked_on > v_event_date THEN
        RAISE EXCEPTION 'Cannot book tickets after event date (%).', v_event_date;
    END IF;

    IF v_seats < p_seat_count THEN
        RAISE EXCEPTION 'Insufficient seats remaining. Available: %, Requested: %',
            v_seats, p_seat_count;
    END IF;

    INSERT INTO bookings (event_id, customer_name, seat_count, total_amount, booked_on)
    VALUES (p_event_id, p_customer_name, p_seat_count, v_total, p_booked_on);

    UPDATE events
    SET seats_remaining = seats_remaining - p_seat_count
    WHERE event_id = p_event_id;
END;
$$;

-- (d) Trigger: Audit changes to seats_remaining
CREATE OR REPLACE FUNCTION fn_audit_event_seats()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.seats_remaining IS DISTINCT FROM NEW.seats_remaining THEN
        INSERT INTO ticket_audit (event_id, old_seats, new_seats, changed_at)
        VALUES (NEW.event_id, OLD.seats_remaining, NEW.seats_remaining, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_events_seats_audit
AFTER UPDATE ON events
FOR EACH ROW
EXECUTE FUNCTION fn_audit_event_seats();

-- Load 6 valid bookings through the procedure (triggers ticket_audit automatically)
CALL pr_book_tickets(1, 'Thabo Banda',     4, CURRENT_DATE - 2);
CALL pr_book_tickets(1, 'Mercy Chanda',    2, CURRENT_DATE - 1);
CALL pr_book_tickets(2, 'Simon Phiri',     6, CURRENT_DATE - 2); -- Drops Event 2 seats to 19 (< 20)
CALL pr_book_tickets(2, 'Lillian Tembo',   4, CURRENT_DATE - 1); -- Drops Event 2 seats to 15
CALL pr_book_tickets(3, 'George Mwale',    5, CURRENT_DATE - 5); -- Booked before past event date
CALL pr_book_tickets(1, 'Beatrice Zulu',   3, CURRENT_DATE);

-- (e) View: v_almost_sold_out
CREATE OR REPLACE VIEW v_almost_sold_out AS
SELECT event_id, event_name, event_date, ticket_price, seats_remaining
FROM events
WHERE seats_remaining < 20
  AND event_date >= CURRENT_DATE;

SELECT * FROM v_almost_sold_out;

-- (f) Index and EXPLAIN
-- Justification: A composite B-tree index on (event_id, booked_on) accelerates queries
-- filtering bookings by a specific event over a date range.
CREATE INDEX idx_bookings_event_date ON bookings (event_id, booked_on);

EXPLAIN ANALYZE
SELECT * FROM bookings
WHERE event_id = 1
  AND booked_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled Job: pr_refresh_tickets
CREATE OR REPLACE PROCEDURE pr_refresh_tickets(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INT;
    v_seats INT;
    v_revenue NUMERIC(12, 2);
BEGIN
    SELECT COUNT(*), COALESCE(SUM(seat_count), 0), COALESCE(SUM(total_amount), 0.00)
    INTO v_count, v_seats, v_revenue
    FROM bookings
    WHERE booked_on = p_day;

    INSERT INTO ticket_summary (summary_date, booking_count, seats_sold, total_revenue)
    VALUES (p_day, v_count, v_seats, v_revenue)
    ON CONFLICT (summary_date)
    DO UPDATE SET
        booking_count = EXCLUDED.booking_count,
        seats_sold = EXCLUDED.seats_sold,
        total_revenue = EXCLUDED.total_revenue;
END;
$$;

-- Schedule daily at 00:50 for the previous day
SELECT cron.schedule(
    'q8_refresh_ticket_summary',
    '50 0 * * *',
    $$CALL pr_refresh_tickets(CURRENT_DATE - INTERVAL '1 day');$$
);
