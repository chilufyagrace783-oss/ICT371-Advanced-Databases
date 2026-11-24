 ICT371 Advanced Database - Question 4: Clinic Appointment Scheduling
   DBMS: PostgreSQL

DROP TABLE IF EXISTS clinic_summary, appointments, doctors, patients CASCADE;

-- (a) Database and Seed Data
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id SERIAL PRIMARY KEY,
    patient_id INT NOT NULL REFERENCES patients(patient_id),
    doctor_id INT NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time TIME NOT NULL CHECK (slot_time IN ('09:00:00', '10:00:00', '11:00:00', '12:00:00')),
    status VARCHAR(15) NOT NULL CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date DATE PRIMARY KEY,
    booked_count INT NOT NULL DEFAULT 0,
    attended_count INT NOT NULL DEFAULT 0,
    cancelled_count INT NOT NULL DEFAULT 0
);

INSERT INTO patients (full_name) VALUES
('Alice Mbewe'),
('Brian Kasonde'),
('Cynthia Njobvu');

INSERT INTO doctors (full_name) VALUES
('Dr. Joseph Musonda'),
('Dr. Ruth Sichone'),
('Dr. David Kabwe');

-- Six valid appointments without violating slot clash rules
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
(1, 1, CURRENT_DATE, '09:00:00', 'BOOKED'),
(2, 1, CURRENT_DATE, '10:00:00', 'BOOKED'),
(3, 2, CURRENT_DATE, '09:00:00', 'BOOKED'),
(1, 2, CURRENT_DATE - 1, '11:00:00', 'ATTENDED'),
(2, 3, CURRENT_DATE - 1, '12:00:00', 'CANCELLED'),
(3, 3, CURRENT_DATE - 1, '12:00:00', 'ATTENDED'); -- Valid because previous 12:00 was CANCELLED

-- (b) Function: fn_daily_load
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INT;
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor ID: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_count;
END;
$$;

-- (c) Procedure: pr_book_appointment
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INT,
    p_doctor_id INT,
    p_day DATE,
    p_slot TIME
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient ID: %', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor ID: %', p_doctor_id;
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date cannot be in the past.';
    END IF;

    IF p_slot IS NULL OR p_slot NOT IN ('09:00:00', '10:00:00', '11:00:00', '12:00:00') THEN
        RAISE EXCEPTION 'Unsupported slot time: %. Allowed: 09:00, 10:00, 11:00, 12:00.', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- (d) Trigger: Reject slot clashes on INSERT or UPDATE
CREATE OR REPLACE FUNCTION fn_check_appointment_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        IF EXISTS (
            SELECT 1
            FROM appointments
            WHERE doctor_id = NEW.doctor_id
              AND appointment_day = NEW.appointment_day
              AND slot_time = NEW.slot_time
              AND status <> 'CANCELLED'
              AND (TG_OP = 'INSERT' OR appointment_id <> NEW.appointment_id)
        ) THEN
            RAISE EXCEPTION 'Slot clash: Doctor % already has a non-cancelled appointment on % at %.',
                NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_no_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION fn_check_appointment_clash();

-- (e) View: v_today_appointments
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT
    a.appointment_id,
    p.full_name AS patient_name,
    d.full_name AS doctor_name,
    a.slot_time
FROM appointments a
JOIN patients p ON a.patient_id = p.patient_id
JOIN doctors d ON a.doctor_id = d.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments;

-- (f) Index and EXPLAIN
-- Justification: A non-unique composite index on (appointment_day, doctor_id) enables
-- direct lookup of a doctor's daily schedule without scanning historical appointments.
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);

EXPLAIN ANALYZE
SELECT * FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;

-- (g) Scheduled Job: pr_refresh_clinic_summary
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_booked INT;
    v_attended INT;
    v_cancelled INT;
BEGIN
    SELECT
        COUNT(*) FILTER (WHERE status = 'BOOKED'),
        COUNT(*) FILTER (WHERE status = 'ATTENDED'),
        COUNT(*) FILTER (WHERE status = 'CANCELLED')
    INTO v_booked, v_attended, v_cancelled
    FROM appointments
    WHERE appointment_day = p_day;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    VALUES (p_day, v_booked, v_attended, v_cancelled)
    ON CONFLICT (summary_date)
    DO UPDATE SET
        booked_count = EXCLUDED.booked_count,
        attended_count = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

-- Schedule daily at 01:00 for the previous day
SELECT cron.schedule(
    'q4_refresh_clinic_summary',
    '0 1 * * *',
    $$CALL pr_refresh_clinic_summary(CURRENT_DATE - INTERVAL '1 day');$$
);
