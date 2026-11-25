-- ============================================================================
-- ICT371: ADVANCED DATABASE - COMPLETE ASSIGNMENT SOLUTIONS (QUESTIONS 1 - 10)
-- Target DBMS: PostgreSQL (with PL/pgSQL and pg_cron extension)
-- ============================================================================

-- Enable pg_cron extension for scheduled jobs (run once as superuser if needed)
CREATE EXTENSION IF NOT EXISTS pg_cron;


-- ============================================================================
-- QUESTION 1: PHARMACY STOCK AND DAILY SALES
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS q1_pharmacy;
SET search_path TO q1_pharmacy, public;

-- (a) Tables and Constraints
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price    NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER NOT NULL,
    new_qty     INTEGER NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER NOT NULL DEFAULT 0,
    total_amount NUMERIC(12, 2) NOT NULL DEFAULT 0.00
);

-- (b) Function: fn_sale_value
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10, 2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %. Quantity must be positive.', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine ID: %', p_medicine_id;
    END IF;

    RETURN ROUND(v_price * p_quantity, 2);
END;
$$;

-- (c) Procedure: pr_record_sale
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity    INTEGER,
    p_sold_on     DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10, 2);
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive.';
    END IF;

    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date cannot be NULL.';
    END IF;

    -- Lock row to prevent race conditions and overselling
    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine ID % does not exist.', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine ID %. Available: %, Requested: %',
            p_medicine_id, v_stock, p_quantity;
    END IF;

    -- Insert sale record using current unit_price
    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    -- Deduct stock exactly once
    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- (d) Trigger: AFTER UPDATE on medicines
CREATE OR REPLACE FUNCTION trg_fn_audit_medicine_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.new_qty, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
EXECUTE FUNCTION trg_fn_audit_medicine_stock();

-- (a) Seed Data (Medicines and 6 valid sales loaded via pr_record_sale)
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 15.00, 50),
    ('Amoxicillin 250mg', 45.50, 14),
    ('Ibuprofen 400mg',   25.00, 20);

CALL pr_record_sale(1, 10, CURRENT_DATE - 2);
CALL pr_record_sale(1, 5,  CURRENT_DATE - 1);
CALL pr_record_sale(2, 6,  CURRENT_DATE - 1); -- Drops Amoxicillin stock to 8 (< 10)
CALL pr_record_sale(3, 4,  CURRENT_DATE - 1);
CALL pr_record_sale(2, 2,  CURRENT_DATE);
CALL pr_record_sale(3, 8,  CURRENT_DATE);

-- (e) View: v_low_stock
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty
FROM medicines
WHERE stock_qty < 10;

-- Query the view after sales
SELECT * FROM v_low_stock;

-- (f) Index and EXPLAIN
-- Justification: A composite B-tree index on (medicine_id, sold_on) allows PostgreSQL
-- to filter directly to a single medicine's entries and perform an efficient range
-- scan on sold_on without scanning the entire sales table.
CREATE INDEX idx_sales_medicine_date ON sales (medicine_id, sold_on);

EXPLAIN
SELECT sale_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled Job: pr_refresh_sales
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_qty    INTEGER;
    v_total_amount NUMERIC(12, 2);
BEGIN
    SELECT COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0.00)
    INTO v_total_qty, v_total_amount
    FROM sales
    WHERE sold_on = p_day;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    VALUES (p_day, v_total_qty, v_total_amount)
    ON CONFLICT (sales_date) DO UPDATE
    SET total_qty    = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- Schedule daily at 00:15 for the previous day
SELECT cron.schedule(
    'q1_refresh_daily_sales',
    '15 0 * * *',
    $$CALL q1_pharmacy.pr_refresh_sales(CURRENT_DATE - 1);$$
);


-- ============================================================================
-- QUESTION 2: UNIVERSITY FEE PAYMENTS
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS q2_university;
SET search_path TO q2_university, public;

-- (a) Tables and Constraints
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL,
    fee_due        NUMERIC(12, 2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12, 2) NOT NULL CHECK (amount > 0),
    paid_on    DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12, 2) NOT NULL,
    logged_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER NOT NULL DEFAULT 0,
    total_amount    NUMERIC(12, 2) NOT NULL DEFAULT 0.00
);

-- (b) Function: fn_fee_balance
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due    NUMERIC(12, 2);
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
    p_student_id INTEGER,
    p_amount     NUMERIC,
    p_paid_on    DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12, 2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive and non-NULL.';
    END IF;

    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date cannot be NULL.';
    END IF;

    -- Lock student row to serialize concurrent payments
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student ID % does not exist.', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Overpayment rejected. Amount (%) exceeds balance (%).', p_amount, v_balance;
    END IF;

    -- Insert valid payment without altering students.fee_due
    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- (d) Trigger: AFTER INSERT on payments
CREATE OR REPLACE FUNCTION trg_fn_audit_payment()
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
EXECUTE FUNCTION trg_fn_audit_payment();

-- (a) Seed Data (3 students, 6 payments; student 3 initially has no payments)
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('STU2026001', 'Chanda Mwamba',   12000.00),
    ('STU2026002', 'Bwalya Phiri',    10000.00),
    ('STU2026003', 'Mutale Tembo',     8500.00);

CALL pr_receive_payment(1, 3000.00, CURRENT_DATE - 5);
CALL pr_receive_payment(1, 2500.00, CURRENT_DATE - 3);
CALL pr_receive_payment(1, 1500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 4000.00, CURRENT_DATE - 4);
CALL pr_receive_payment(2, 3500.00, CURRENT_DATE - 2);
CALL pr_receive_payment(2, 2500.00, CURRENT_DATE - 1); -- Student 2 is now fully settled

-- (e) View: v_fee_balances
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    s.fee_due - COALESCE(SUM(p.amount), 0.00) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0.00) > 0;

-- (f) Index and Plan
-- Justification: Placing student_id first narrows lookups to a single student via
-- equality, while paid_on second supports ordered range scans between two dates.
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);

EXPLAIN
SELECT payment_id, amount, paid_on
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN CURRENT_DATE - 10 AND CURRENT_DATE;

-- (g) Scheduled Job: pr_refresh_collections
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count  INTEGER;
    v_amount NUMERIC(12, 2);
BEGIN
    SELECT COUNT(*), COALESCE(SUM(amount), 0.00)
    INTO v_count, v_amount
    FROM payments
    WHERE paid_on = p_day;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    VALUES (p_day, v_count, v_amount)
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;
END;
$$;

SELECT cron.schedule(
    'q2_refresh_daily_collections',
    '0 1 * * *',
    $$CALL q2_university.pr_refresh_collections(CURRENT_DATE - 1);$$
);


-- ============================================================================
-- QUESTION 3: LIBRARY RETURNS AND OVERDUE FINES
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS q3_library;
SET search_path TO q3_library, public;

-- (a) Tables and Constraints
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL CHECK (due_on >= borrowed_on),
    returned_on   DATE NULL CHECK (returned_on IS NULL OR returned_on >= borrowed_on),
    fine_amount   NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (fine_amount >= 0)
);

CREATE TABLE loan_audit (
    audit_id        SERIAL PRIMARY KEY,
    loan_id         INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE NULL,
    new_returned_on DATE NULL,
    changed_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL DEFAULT 0,
    total_fine    NUMERIC(12, 2) NOT NULL DEFAULT 0.00
);

-- (b) Function: fn_loan_fine
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due_on        DATE;
    v_returned_on   DATE;
    v_effective_end DATE;
    v_overdue_days  INTEGER;
BEGIN
    SELECT due_on, returned_on
    INTO v_due_on, v_returned_on
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
    RETURN (v_overdue_days * 2)::NUMERIC(10, 2);
END;
$$;

-- (c) Procedure: pr_return_loan
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed_on DATE;
    v_returned_on DATE;
    v_final_fine  NUMERIC(10, 2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date cannot be NULL.';
    END IF;

    SELECT borrowed_on, returned_on
    INTO v_borrowed_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan ID: %', p_loan_id;
    END IF;

    IF v_returned_on IS NOT NULL THEN
        RAISE EXCEPTION 'Loan ID % has already been returned on %.', p_loan_id, v_returned_on;
    END IF;

    IF p_returned_on < v_borrowed_on THEN
        RAISE EXCEPTION 'Return date (%) cannot be before borrow date (%).', p_returned_on, v_borrowed_on;
    END IF;

    -- Temporarily compute fine as of p_returned_on
    SELECT GREATEST(0, p_returned_on - due_on) * 2
    INTO v_final_fine
    FROM loans
    WHERE loan_id = p_loan_id;

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_final_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- (d) Trigger: AFTER UPDATE on loans
CREATE OR REPLACE FUNCTION trg_fn_audit_loan_return()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_return_audit
AFTER UPDATE ON loans
FOR EACH ROW
EXECUTE FUNCTION trg_fn_audit_loan_return();

-- (a) Seed Data (3 books, 6 loans: open overdue, on-time, returned)
INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('PostgreSQL Internals'),
    ('Distributed Data Systems');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
    (1, 'Alice Banda',   CURRENT_DATE - 15, CURRENT_DATE - 5, NULL, 0.00),             -- Open overdue
    (2, 'Brian Mulenga', CURRENT_DATE - 12, CURRENT_DATE - 2, NULL, 0.00),             -- Open overdue
    (3, 'Chisomo Zulu',  CURRENT_DATE - 3,  CURRENT_DATE + 4, NULL, 0.00),             -- Open on-time
    (1, 'Derrick Sakala',CURRENT_DATE - 1,  CURRENT_DATE + 6, NULL, 0.00),             -- Open on-time
    (2, 'Esther Lungu',  CURRENT_DATE - 10, CURRENT_DATE - 3, CURRENT_DATE - 4, 0.00), -- Returned on-time
    (3, 'Frank Musonda', CURRENT_DATE - 14, CURRENT_DATE - 7, CURRENT_DATE - 5, 4.00); -- Returned late (2 days * K2)

-- (e) View: v_overdue_loans
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    b.title AS book_title,
    l.borrower_name,
    l.due_on,
    fn_loan_fine(l.loan_id, CURRENT_DATE) AS current_fine
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

-- (f) Index and EXPLAIN
-- A partial index on book_id WHERE returned_on IS NULL keeps the index compact
-- and directly serves searches for a specific book's active unreturned loans.
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;

EXPLAIN
SELECT loan_id, borrower_name, borrowed_on, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;

-- (g) Scheduled Job: pr_refresh_overdue
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
    v_total NUMERIC(12, 2);
BEGIN
    SELECT COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0.00)
    INTO v_count, v_total
    FROM loans
    WHERE returned_on IS NULL OR returned_on > p_as_of;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    VALUES (p_as_of, v_count, v_total)
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine    = EXCLUDED.total_fine;
END;
$$;

SELECT cron.schedule(
    'q3_refresh_overdue_summary',
    '10 0 * * *',
    $$CALL q3_library.pr_refresh_overdue(CURRENT_DATE);$$
);


-- ============================================================================
-- QUESTION 4: CLINIC APPOINTMENT SCHEDULING
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS q4_clinic;
SET search_path TO q4_clinic, public;

-- (a) Tables and Constraints
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL CHECK (slot_time IN ('09:00:00', '10:00:00', '11:00:00', '12:00:00')),
    status          VARCHAR(15) NOT NULL CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL DEFAULT 0,
    attended_count  INTEGER NOT NULL DEFAULT 0,
    cancelled_count INTEGER NOT NULL DEFAULT 0
);

-- (b) Function: fn_daily_load
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
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
    p_patient_id INTEGER,
    p_doctor_id  INTEGER,
    p_day        DATE,
    p_slot       TIME
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
        RAISE EXCEPTION 'Appointment date (%) cannot be in the past.', p_day;
    END IF;

    IF p_slot NOT IN ('09:00:00'::TIME, '10:00:00'::TIME, '11:00:00'::TIME, '12:00:00'::TIME) THEN
        RAISE EXCEPTION 'Unsupported slot time: %. Allowed slots: 09:00, 10:00, 11:00, 12:00.', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- (d) Trigger: BEFORE INSERT OR UPDATE on appointments
CREATE OR REPLACE FUNCTION trg_fn_prevent_slot_clash()
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
EXECUTE FUNCTION trg_fn_prevent_slot_clash();

-- (a) Seed Data (3 patients, 3 doctors, 6 valid appointments)
INSERT INTO patients (full_name) VALUES
    ('Grace Kasonde'),
    ('Henry Mwale'),
    ('Irene Chileshe');

INSERT INTO doctors (full_name) VALUES
    ('Dr. M. Simwanza'),
    ('Dr. K. Ngoma'),
    ('Dr. T. Silwamba');

INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE,     '09:00:00', 'BOOKED'),
    (2, 1, CURRENT_DATE,     '10:00:00', 'BOOKED'),
    (3, 1, CURRENT_DATE,     '09:00:00', 'CANCELLED'), -- Cancelled, so no clash with row 1
    (1, 2, CURRENT_DATE,     '11:00:00', 'ATTENDED'),
    (2, 2, CURRENT_DATE + 1, '09:00:00', 'BOOKED'),
    (3, 3, CURRENT_DATE + 1, '12:00:00', 'BOOKED');

-- (e) View: v_today_appointments
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT
    p.full_name AS patient_name,
    d.full_name AS doctor_name,
    a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors d  ON d.doctor_id = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

-- (f) Index and Plan
-- Justification: A non-unique composite index on (appointment_day, doctor_id)
-- accelerates daily schedule lookups filtered by date and optionally doctor_id,
-- while permitting multiple slots and cancelled rows for the same doctor and day.
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);

EXPLAIN
SELECT appointment_id, patient_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;

-- (g) Scheduled Job: pr_refresh_clinic_summary
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_booked    INTEGER;
    v_attended  INTEGER;
    v_cancelled INTEGER;
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
    ON CONFLICT (summary_date) DO UPDATE
    SET booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

SELECT cron.schedule(
    'q4_refresh_clinic_summary',
    '0 1 * * *',
    $$CALL q4_clinic.pr_refresh_clinic_summary(CURRENT_DATE - 1);$$
);


-- ============================================================================
-- QUESTION 5: HOSTEL ROOM ALLOCATION
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS q5_hostel;
SET search_path TO q5_hostel, public;

-- (a) Tables and Constraints
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(20) NOT NULL UNIQUE,
    capacity    INTEGER NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER NOT NULL REFERENCES students(student_id),
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE NOT NULL,
    released_on   DATE NULL,
    status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT chk_allocation_status_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL,
    free_beds     INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

-- (b) Function: fn_free_beds
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_occupied INTEGER;
BEGIN
    SELECT capacity INTO v_capacity
    FROM rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room ID: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_occupied
    FROM allocations
    WHERE room_id = p_room_id
      AND status = 'ACTIVE';

    RETURN v_capacity - v_occupied;
END;
$$;

-- (c) Procedure: pr_allocate_room
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INTEGER,
    p_room_id      INTEGER,
    p_allocated_on DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student ID: %', p_student_id;
    END IF;

    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room ID: %', p_room_id;
    END IF;

    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date cannot be NULL.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM allocations
        WHERE student_id = p_student_id AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'Student ID % already has an ACTIVE room allocation.', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room ID % has no free beds.', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- (d) Trigger: BEFORE INSERT OR UPDATE on allocations
CREATE OR REPLACE FUNCTION trg_fn_enforce_hostel_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity     INTEGER;
    v_active_room  INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        -- Enforce one ACTIVE allocation per student
        IF EXISTS (
            SELECT 1 FROM allocations
            WHERE student_id = NEW.student_id
              AND status = 'ACTIVE'
              AND (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id)
        ) THEN
            RAISE EXCEPTION 'Student % already holds an ACTIVE allocation.', NEW.student_id;
        END IF;

        -- Enforce room capacity
        SELECT capacity INTO v_capacity
        FROM rooms
        WHERE room_id = NEW.room_id
        FOR UPDATE;

        SELECT COUNT(*) INTO v_active_room
        FROM allocations
        WHERE room_id = NEW.room_id
          AND status = 'ACTIVE'
          AND (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id);

        IF v_active_room >= v_capacity THEN
            RAISE EXCEPTION 'Room % is at full capacity (%).', NEW.room_id, v_capacity;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_enforce_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_enforce_hostel_rules();

-- (a) Seed Data (Full room, partly occupied room, empty room)
INSERT INTO rooms (room_number, capacity) VALUES
    ('H1-101', 2), -- Will be full
    ('H1-102', 3), -- Will be partly occupied
    ('H1-103', 2); -- Will be empty

INSERT INTO students (student_number, full_name) VALUES
    ('HS001', 'John Kunda'),
    ('HS002', 'Kelvin Mubita'),
    ('HS003', 'Linda Phiri'),
    ('HS004', 'Mary Chanda');

INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
    (1, 1, CURRENT_DATE - 30, CURRENT_DATE - 10, 'ENDED'), -- Historical ended allocation
    (1, 1, CURRENT_DATE - 9,  NULL, 'ACTIVE'),
    (2, 1, CURRENT_DATE - 9,  NULL, 'ACTIVE'),              -- Room H1-101 now full (2/2)
    (3, 2, CURRENT_DATE - 5,  NULL, 'ACTIVE');              -- Room H1-102 partly occupied (1/3); H1-103 empty (0/2)

-- (e) View: v_room_occupancy
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT
    r.room_id,
    r.room_number,
    r.capacity,
    COUNT(a.allocation_id) AS occupied_beds,
    r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a
    ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

-- (f) Index and EXPLAIN
-- Justification: A partial index on room_id filtered by status = 'ACTIVE' ignores
-- historical ENDED rows, making active bed counts per room fast and compact.
CREATE INDEX idx_allocations_room_active ON allocations (room_id) WHERE status = 'ACTIVE';

EXPLAIN
SELECT allocation_id, student_id, allocated_on
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';

-- (g) Scheduled Job: pr_refresh_occupancy
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
    FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;
END;
$$;

SELECT cron.schedule(
    'q5_refresh_room_occupancy',
    '55 23 * * *',
    $$CALL q5_hostel.pr_refresh_occupancy();$$
);


-- ============================================================================
-- QUESTION 6: MONTHLY PAYROLL PROCESSING
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS q6_payroll;
SET search_path TO q6_payroll, public;

-- (a) Tables and Constraints
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12, 2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12, 2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12, 2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),
    gross_pay   NUMERIC(12, 2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     NUMERIC(12, 2) NOT NULL CHECK (net_pay >= 0),
    UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12, 2) NOT NULL,
    new_salary  NUMERIC(12, 2) NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- (b) Function: fn_net_pay
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic     NUMERIC(12, 2);
    v_allowance NUMERIC(12, 2);
    v_deduction NUMERIC(12, 2);
    v_net       NUMERIC(12, 2);
BEGIN
    SELECT basic_salary, allowance, deduction
    INTO v_basic, v_allowance, v_deduction
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee ID: %', p_employee_id;
    END IF;

    v_net := (v_basic + v_allowance) - v_deduction;

    IF v_net < 0 THEN
        RAISE EXCEPTION 'Computed net pay (%) is negative for employee ID %.', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

-- (c) Procedure: pr_process_payroll
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    rec       RECORD;
    v_gross   NUMERIC(12, 2);
    v_net     NUMERIC(12, 2);
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month (%) must be the first day of a month.', p_month;
    END IF;

    FOR rec IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active = TRUE
    LOOP
        v_net   := fn_net_pay(rec.employee_id);
        v_gross := rec.basic_salary + rec.allowance;

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- (d) Trigger: AFTER UPDATE on employees
CREATE OR REPLACE FUNCTION trg_fn_audit_salary_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
        VALUES (NEW.employee_id, OLD.basic_salary, NEW.new_salary, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
EXECUTE FUNCTION trg_fn_audit_salary_change();

-- (a) Seed Data (Active and inactive employees, 2 payroll months)
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Moses Chipimo',  15000.00, 2500.00, 1800.00, TRUE),
    ('Nelly Mutale',   12000.00, 2000.00, 1200.00, TRUE),
    ('Oscar Mbewe',    10000.00, 1500.00, 1000.00, TRUE);

CALL pr_process_payroll('2026-09-01');
-- Deactivate Oscar Mbewe before October payroll
UPDATE employees SET active = FALSE WHERE employee_id = 3;
CALL pr_process_payroll('2026-10-01');

-- (e) View: v_payroll_report
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT
    e.full_name,
    p.pay_month,
    p.gross_pay,
    p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

-- (f) Index
-- Justification: The existing unique index is ordered (employee_id, pay_month),
-- which cannot efficiently filter by pay_month alone across all employees.
-- A dedicated index on (pay_month) avoids a full table scan for monthly reports.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

-- (g) Scheduled Job & Inspection Queries
SELECT cron.schedule(
    'q6_monthly_payroll',
    '0 2 1 * *',
    $$CALL q6_payroll.pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE);$$
);

-- Inspect scheduled job and run history:
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'q6_monthly_payroll';

SELECT runid, jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
ORDER BY start_time DESC
LIMIT 10;


-- ============================================================================
-- QUESTION 7: WATER METER READINGS AND BILLING
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS q7_water;
SET search_path TO q7_water, public;

-- (a) Tables and Constraints
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
    previous_reading NUMERIC(10, 2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10, 2) NOT NULL CHECK (current_reading >= 0),
    UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12, 2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (amount_paid >= 0 AND amount_paid <= charge),
    due_on      DATE NOT NULL
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(12, 2) NOT NULL DEFAULT 0.00
);

-- (b) Function: fn_water_charge
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_charge NUMERIC(12, 2);
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Consumption units (%) must be non-NULL and non-negative.', p_units;
    END IF;

    IF p_units = 0 THEN
        v_charge := 0.00;
    ELSIF p_units <= 10 THEN
        v_charge := p_units * 5.00;
    ELSE
        v_charge := (10 * 5.00) + ((p_units - 10) * 8.00);
    END IF;

    RETURN ROUND(v_charge, 2);
END;
$$;

-- (c) Procedure: pr_generate_bill
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev   NUMERIC(10, 2);
    v_curr   NUMERIC(10, 2);
    v_charge NUMERIC(12, 2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date cannot be NULL.';
    END IF;

    SELECT previous_reading, current_reading
    INTO v_prev, v_curr
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading ID: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading ID % already has a generated bill.', p_reading_id;
    END IF;

    v_charge := fn_water_charge(v_curr - v_prev);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0.00, p_due_on);
END;
$$;

-- (d) Trigger: BEFORE INSERT OR UPDATE on readings
CREATE OR REPLACE FUNCTION trg_fn_validate_meter_reading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'Current reading (%) cannot be below previous reading (%).',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_validate
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_validate_meter_reading();

-- (a) Seed Data (3 customers, 6 readings covering 0, 10, and >10 units)
INSERT INTO customers (full_name) VALUES
    ('Peter Chama'),
    ('Queen Bwalya'),
    ('Robert Sinkala');

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, '2026-09-01', 100.00, 100.00), -- 0 units
    (2, '2026-09-01', 200.00, 210.00), -- 10 units
    (3, '2026-09-01', 350.00, 368.00), -- 18 units (>10)
    (1, '2026-10-01', 100.00, 110.00), -- 10 units
    (2, '2026-10-01', 210.00, 225.00), -- 15 units (>10)
    (3, '2026-10-01', 368.00, 368.00); -- 0 units

CALL pr_generate_bill(1, CURRENT_DATE - 15);
CALL pr_generate_bill(2, CURRENT_DATE - 10);
CALL pr_generate_bill(3, CURRENT_DATE - 5);
CALL pr_generate_bill(4, CURRENT_DATE + 10);
CALL pr_generate_bill(5, CURRENT_DATE + 10);

-- Partial payment on bill 3
UPDATE bills SET amount_paid = 50.00 WHERE bill_id = 3;

-- (e) View: v_overdue_bills
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT
    c.full_name AS customer_name,
    b.due_on,
    (b.charge - b.amount_paid) AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

-- (f) Index and EXPLAIN
-- Justification: A partial index on due_on restricted to unpaid bills
-- (amount_paid < charge) skips settled bills and speeds up overdue date range scans.
CREATE INDEX idx_bills_unpaid_due_on ON bills (due_on) WHERE amount_paid < charge;

EXPLAIN
SELECT bill_id, reading_id, charge, amount_paid, due_on
FROM bills
WHERE due_on < CURRENT_DATE
  AND amount_paid < charge;

-- (g) Scheduled Job: pr_refresh_receivables
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_due NUMERIC(12, 2);
BEGIN
    SELECT COALESCE(SUM(charge - amount_paid), 0.00)
    INTO v_total_due
    FROM bills
    WHERE amount_paid < charge;

    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    VALUES (CURRENT_DATE, v_total_due)
    ON CONFLICT (snapshot_date) DO UPDATE
    SET total_due = EXCLUDED.total_due;
END;
$$;

SELECT cron.schedule(
    'q7_refresh_receivables',
    '30 0 * * *',
    $$CALL q7_water.pr_refresh_receivables();$$
);


-- ============================================================================
-- QUESTION 8: TRANSPORT FLEET MAINTENANCE
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS q8_fleet;
SET search_path TO q8_fleet, public;

-- (a) Tables and Constraints
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(20) NOT NULL UNIQUE,
    current_odometer      INTEGER NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER NOT NULL CHECK (
        last_service_odometer >= 0 AND last_service_odometer <= current_odometer
    )
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INTEGER NOT NULL CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INTEGER NOT NULL,
    flagged_on       DATE NOT NULL DEFAULT CURRENT_DATE
);

-- (b) Function: fn_service_due
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr INTEGER;
    v_last INTEGER;
BEGIN
    SELECT current_odometer, last_service_odometer
    INTO v_curr, v_last
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle ID: %', p_vehicle_id;
    END IF;

    RETURN (v_curr - v_last) >= 5000;
END;
$$;

-- (c) Procedure: pr_record_trip
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on    DATE,
    p_start      INTEGER,
    p_end        INTEGER
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle ID: %', p_vehicle_id;
    END IF;

    IF p_trip_on IS NULL THEN
        RAISE EXCEPTION 'Trip date cannot be NULL.';
    END IF;

    IF p_end IS NULL OR p_start IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer (%) must be greater than start odometer (%).', p_end, p_start;
    END IF;

    -- Insert trip only; vehicle odometer is updated by trigger
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- (d) Trigger: BEFORE INSERT on trips
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer_sync()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr_odo INTEGER;
BEGIN
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end_odometer (%) must exceed start_odometer (%).',
            NEW.end_odometer, NEW.start_odometer;
    END IF;

    SELECT current_odometer INTO v_curr_odo
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehicle ID % not found.', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer <> v_curr_odo THEN
        RAISE EXCEPTION 'Trip start odometer (%) does not match vehicle current odometer (%).',
            NEW.start_odometer, v_curr_odo;
    END IF;

    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_before_insert
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer_sync();

-- (a) Seed Data (3 vehicles, 6 trips added through pr_record_trip after trigger)
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('BAA 1001', 10000, 10000), -- Freshly serviced
    ('BAA 2002', 24200, 20000), -- 4,200 km since service (close to threshold)
    ('BAA 3003', 55000, 49500); -- Already overdue (5,500 km since service)

CALL pr_record_trip(1, CURRENT_DATE - 3, 10000, 10450);
CALL pr_record_trip(1, CURRENT_DATE - 1, 10450, 11200);
CALL pr_record_trip(2, CURRENT_DATE - 2, 24200, 24800);
CALL pr_record_trip(2, CURRENT_DATE,     24800, 25300); -- Crosses 5,000 km threshold (5,300 km)
CALL pr_record_trip(3, CURRENT_DATE - 2, 55000, 55400);
CALL pr_record_trip(3, CURRENT_DATE,     55400, 55900);

-- (e) View: v_service_due
CREATE OR REPLACE VIEW v_service_due AS
SELECT
    registration,
    (current_odometer - last_service_odometer) AS km_since_service
FROM vehicles
WHERE (current_odometer - last_service_odometer) >= 5000;

-- (f) Index, EXPLAIN and Justification
-- Justification: A composite index on (vehicle_id, trip_on) allows direct equality
-- filtering on a single vehicle followed by an ordered index range scan on trip_on.
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);

EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 2
  AND trip_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled Job: pr_refresh_service_alerts
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    -- Remove alerts for vehicles no longer due
    DELETE FROM service_alerts sa
    USING vehicles v
    WHERE sa.vehicle_id = v.vehicle_id
      AND (v.current_odometer - v.last_service_odometer) < 5000;

    -- Insert or update alerts for due vehicles
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT
        vehicle_id,
        (current_odometer - last_service_odometer),
        CURRENT_DATE
    FROM vehicles
    WHERE (current_odometer - last_service_odometer) >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service,
        flagged_on       = EXCLUDED.flagged_on;
END;
$$;

SELECT cron.schedule(
    'q8_weekly_service_alerts',
    '0 6 * * 1',
    $$CALL q8_fleet.pr_refresh_service_alerts();$$
);


-- ============================================================================
-- QUESTION 9: FARMER COOPERATIVE MAIZE DELIVERIES
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS q9_maize;
SET search_path TO q9_maize, public;

-- (a) Tables and Constraints
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10, 2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10, 2) NOT NULL,
    total_value  NUMERIC(12, 2) NOT NULL,
    delivered_on DATE NOT NULL,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    total_value   NUMERIC(12, 2) NOT NULL DEFAULT 0.00
);

-- (b) Function: fn_maize_rate
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade cannot be NULL.';
    END IF;

    CASE UPPER(TRIM(p_grade))
        WHEN 'A' THEN RETURN 5.00;
        WHEN 'B' THEN RETURN 4.00;
        WHEN 'C' THEN RETURN 3.00;
        ELSE RAISE EXCEPTION 'Unsupported maize grade: %. Allowed: A, B, C.', p_grade;
    END CASE;
END;
$$;

-- (d) Trigger: BEFORE INSERT OR UPDATE on deliveries
CREATE OR REPLACE FUNCTION trg_fn_calculate_delivery_value()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Delivery weight (%) must be positive.', NEW.weight_kg;
    END IF;

    NEW.grade       := UPPER(TRIM(NEW.grade));
    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_price_calc
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_calculate_delivery_value();

-- (c) Procedure: pr_receive_delivery
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade     CHAR,
    p_weight    NUMERIC,
    p_date      DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown farmer ID: %', p_farmer_id;
    END IF;

    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date cannot be NULL.';
    END IF;

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive.';
    END IF;

    -- Trigger supplies unit_rate and total_value
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- (a) Seed Data (3 farmers, 6 deliveries loaded after trigger installation)
INSERT INTO farmers (farmer_number, full_name) VALUES
    ('FRM-001', 'Samuel Tembo'),
    ('FRM-002', 'Theresa Phiri'),
    ('FRM-003', 'Victor Mwansa');

CALL pr_receive_delivery(1, 'A', 500.00, CURRENT_DATE - 3);
CALL pr_receive_delivery(1, 'B', 300.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'C', 450.00, CURRENT_DATE - 2);
CALL pr_receive_delivery(2, 'A', 200.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'B', 600.00, CURRENT_DATE - 4);
CALL pr_receive_delivery(3, 'A', 250.00, CURRENT_DATE - 1);

-- Mark Farmer 3's deliveries as paid so Farmer 3 has 0 unpaid due
UPDATE deliveries SET is_paid = TRUE WHERE farmer_id = 3;

-- (e) View: v_farmer_amount_due
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT
    f.farmer_number,
    f.full_name,
    COALESCE(SUM(d.total_value), 0.00) AS amount_due
FROM farmers f
LEFT JOIN deliveries d
    ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- (f) Index and EXPLAIN
-- Justification: A composite index on (farmer_id, delivered_on) lets PostgreSQL
-- locate a single farmer's records directly and scan the date range in order.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value, delivered_on
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled Job: pr_refresh_purchases
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_weight NUMERIC(12, 2);
    v_value  NUMERIC(12, 2);
BEGIN
    SELECT COALESCE(SUM(weight_kg), 0.00),
           COALESCE(SUM(total_value), 0.00)
    INTO v_weight, v_value
    FROM deliveries
    WHERE delivered_on = p_day;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    VALUES (p_day, v_weight, v_value)
    ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight,
        total_value  = EXCLUDED.total_value;
END;
$$;

SELECT cron.schedule(
    'q9_refresh_daily_purchases',
    '30 1 * * *',
    $$CALL q9_maize.pr_refresh_purchases(CURRENT_DATE - 1);$$
);


-- ============================================================================
-- QUESTION 10: SCHOLARSHIP APPLICATION ASSESSMENT
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS q10_scholarship;
SET search_path TO q10_scholarship, public;

-- (a) Tables and Constraints
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12, 2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5, 2) NOT NULL CHECK (average_mark >= 0 AND average_mark <= 100),
    submitted_on       DATE NOT NULL DEFAULT CURRENT_DATE,
    status             VARCHAR(15) NOT NULL DEFAULT 'PENDING'
                       CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(15) NOT NULL,
    new_status     VARCHAR(15) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- (b) Function: fn_scholarship_eligible
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INTEGER,
    p_income NUMERIC,
    p_mark   NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income, and mark inputs must not be NULL.';
    END IF;

    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age (%) must be positive.', p_age;
    END IF;

    IF p_income < 0 THEN
        RAISE EXCEPTION 'Monthly income (%) cannot be negative.', p_income;
    END IF;

    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Average mark (%) must be between 0 and 100.', p_mark;
    END IF;

    RETURN (p_age BETWEEN 18 AND 25)
       AND (p_income <= 3000.00)
       AND (p_mark >= 70.00);
END;
$$;

-- (c) Procedure: pr_assess_application
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age      INTEGER;
    v_income   NUMERIC(12, 2);
    v_mark     NUMERIC(5, 2);
    v_status   VARCHAR(15);
    v_eligible BOOLEAN;
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application ID % does not exist.', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application ID % has already been assessed (status: %).',
            p_application_id, v_status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);

    UPDATE applications
    SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- (d) Trigger: AFTER UPDATE on applications
CREATE OR REPLACE FUNCTION trg_fn_audit_application_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_status_audit
AFTER UPDATE ON applications
FOR EACH ROW
EXECUTE FUNCTION trg_fn_audit_application_status();

-- (a) Seed Data (3 students, 6 PENDING applications covering qualifying, non-qualifying, and boundary cases)
INSERT INTO students (student_number, full_name) VALUES
    ('SCH-101', 'Womba Katongo'),
    ('SCH-102', 'Yolanda Chanda'),
    ('SCH-103', 'Zackary Mwanza');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 4, 'PENDING'), -- Boundary qualifying (exact min age, max income, min mark)
    (2, 25, 1800.00, 84.50, CURRENT_DATE - 3, 'PENDING'), -- Boundary max age qualifying
    (3, 21, 2500.00, 78.00, CURRENT_DATE - 3, 'PENDING'), -- Standard qualifying
    (1, 17, 1500.00, 88.00, CURRENT_DATE - 2, 'PENDING'), -- Boundary fail: age 17 (< 18)
    (2, 22, 3001.00, 80.00, CURRENT_DATE - 2, 'PENDING'), -- Boundary fail: income 3001 (> 3000)
    (3, 20, 2000.00, 69.99, CURRENT_DATE - 1, 'PENDING'); -- Boundary fail: mark 69.99 (< 70)

-- (e) View: v_approved_applicants
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Index and EXPLAIN
-- Justification: A composite index on (status, submitted_on) filters by exact status
-- first (e.g. 'PENDING') and then scans submitted_on chronologically within that status.
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);

EXPLAIN
SELECT application_id, student_id, submitted_on
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled Job: pr_assess_pending
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

SELECT cron.schedule(
    'q10_weekly_assess_pending',
    '0 8 * * 1',
    $$CALL q10_scholarship.pr_assess_pending();$$
);

-- Reset search_path
SET search_path TO public; 
