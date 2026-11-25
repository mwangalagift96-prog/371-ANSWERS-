-- ICT371 Q9 Farmer Cooperative Maize Deliveries (PostgreSQL + pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

-- (a) Tables
CREATE TABLE farmers (
  farmer_id     SERIAL PRIMARY KEY,
  farmer_number VARCHAR(20) NOT NULL UNIQUE,
  full_name     VARCHAR(100) NOT NULL
);
CREATE TABLE deliveries (
  delivery_id  SERIAL PRIMARY KEY,
  farmer_id    INT NOT NULL REFERENCES farmers(farmer_id),
  grade        CHAR(1) NOT NULL CHECK (grade IN ('A','B','C')),
  weight_kg    NUMERIC(12,2) NOT NULL,
  unit_rate    NUMERIC(10,2) NOT NULL,   -- supplied by trigger
  total_value  NUMERIC(14,2) NOT NULL,   -- supplied by trigger
  delivered_on DATE NOT NULL,
  is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases (
  purchase_date DATE PRIMARY KEY,
  total_weight  NUMERIC(14,2) NOT NULL,
  total_value   NUMERIC(14,2) NOT NULL
);

-- (b) Function: A = K5, B = K4, C = K3
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v_rate NUMERIC;
BEGIN
  IF p_grade IS NULL THEN
    RAISE EXCEPTION 'Grade is required';
  END IF;
  v_rate := CASE p_grade WHEN 'A' THEN 5.00 WHEN 'B' THEN 4.00 WHEN 'C' THEN 3.00 END;
  IF v_rate IS NULL THEN
    RAISE EXCEPTION 'Unsupported grade: %', p_grade;
  END IF;
  RETURN v_rate;
END $$;

-- (d) Trigger: one pricing rule for procedure and direct SQL
CREATE OR REPLACE FUNCTION trg_price_delivery() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
    RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
  END IF;
  NEW.unit_rate   := fn_maize_rate(NEW.grade);
  NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
  RETURN NEW;
END $$;
CREATE TRIGGER trg_deliveries_price
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_price_delivery();

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade TEXT, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id; END IF;
  IF p_grade IS NULL OR p_grade NOT IN ('A','B','C') THEN
    RAISE EXCEPTION 'Invalid grade: %', p_grade;
  END IF;
  IF p_weight IS NULL OR p_weight <= 0 THEN
    RAISE EXCEPTION 'Weight must be positive, got %', p_weight;
  END IF;
  IF p_date IS NULL THEN RAISE EXCEPTION 'Delivery date is required'; END IF;
  INSERT INTO deliveries(farmer_id, grade, weight_kg, delivered_on, is_paid)
  VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);   -- trigger fills rate and value
END $$;

-- (a) Seed (after the trigger): basic fields only, rate/value come from the trigger
INSERT INTO farmers(farmer_number, full_name) VALUES
 ('F001','Joseph Mutale'), ('F002','Lucy Kunda'), ('F003','Moses Sinkala');
INSERT INTO deliveries(farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
 (1,'A', 200.00, CURRENT_DATE - 3, TRUE),
 (1,'B', 150.50, CURRENT_DATE - 1, FALSE),
 (2,'C', 300.00, CURRENT_DATE - 1, FALSE),
 (2,'A',  80.25, CURRENT_DATE - 2, TRUE),
 (1,'C',  50.00, CURRENT_DATE - 1, TRUE),
 (2,'B', 120.00, CURRENT_DATE - 1, FALSE);      -- farmer 3 has no deliveries

-- (e) View
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name, COALESCE(SUM(d.total_value), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- (f) Composite index: equality (farmer_id) then range (delivered_on)
CREATE INDEX idx_deliveries_farmer_date ON deliveries(farmer_id, delivered_on);

-- (g) Refresh procedure (overwrites, never adds)
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_purchases(purchase_date, total_weight, total_value)
  SELECT p_day, COALESCE(SUM(weight_kg),0), COALESCE(SUM(total_value),0)
  FROM deliveries WHERE delivered_on = p_day
  ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight, total_value = EXCLUDED.total_value;
END $$;

SELECT cron.schedule('refresh-purchases', '30 1 * * *', $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);

---------------------------- TESTS / EVIDENCE ----------------------------
SELECT fn_maize_rate('A'), fn_maize_rate('B'), fn_maize_rate('C');
DO $$ BEGIN PERFORM fn_maize_rate(NULL);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_maize_rate('D');
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'A', -5, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
CALL pr_receive_delivery(3, 'A', 10, CURRENT_DATE);               -- 10 kg x K5 = 50.00
-- Direct SQL cannot bypass pricing: the wrong rate supplied here is overwritten
INSERT INTO deliveries(farmer_id,grade,weight_kg,unit_rate,total_value,delivered_on)
VALUES (3,'B',10,99,9999,CURRENT_DATE);                           -- stored as 4.00 / 40.00
SELECT delivery_id, grade, weight_kg, unit_rate, total_value, is_paid FROM deliveries ORDER BY 1;
SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;
CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);                      -- rerun replaces
SELECT * FROM daily_purchases;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM deliveries
WHERE farmer_id = 1 AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;
SELECT jobid, jobname, schedule FROM cron.job;
