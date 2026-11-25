-- ICT371 Q1 Pharmacy Stock and Daily Sales (PostgreSQL + pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS daily_sales, stock_audit, sales, medicines CASCADE;

-- (a) Tables
CREATE TABLE medicines (
  medicine_id   SERIAL PRIMARY KEY,
  medicine_name VARCHAR(100)  NOT NULL,
  unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  stock_qty     INT           NOT NULL CHECK (stock_qty >= 0)
);
CREATE TABLE sales (
  sale_id     SERIAL PRIMARY KEY,
  medicine_id INT           NOT NULL REFERENCES medicines(medicine_id),
  quantity    INT           NOT NULL CHECK (quantity > 0),
  unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  sold_on     DATE          NOT NULL
);
CREATE TABLE stock_audit (
  audit_id    SERIAL PRIMARY KEY,
  medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
  old_qty     INT NOT NULL,
  new_qty     INT NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_sales (
  sales_date   DATE PRIMARY KEY,
  total_qty    INT           NOT NULL DEFAULT 0,
  total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC(10,2);
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
  END IF;
  SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
  END IF;
  RETURN v_price * p_quantity;
END $$;

-- (c) Procedure (row lock prevents two sessions overselling the same stock)
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC(10,2); v_stock INT;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
  END IF;
  IF p_sold_on IS NULL THEN
    RAISE EXCEPTION 'Sale date is required';
  END IF;
  SELECT unit_price, stock_qty INTO v_price, v_stock
  FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
  END IF;
  IF v_stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock for medicine %: available %, requested %',
                    p_medicine_id, v_stock, p_quantity;
  END IF;
  INSERT INTO sales(medicine_id, quantity, unit_price, sold_on)
  VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);
  UPDATE medicines SET stock_qty = stock_qty - p_quantity WHERE medicine_id = p_medicine_id;
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_stock_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO stock_audit(medicine_id, old_qty, new_qty)
  VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
  RETURN NEW;
END $$;
CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_stock_audit();

-- (a) Seed data: medicines, then sales loaded through the procedure
INSERT INTO medicines(medicine_name, unit_price, stock_qty) VALUES
 ('Paracetamol 500mg', 2.50, 100),
 ('Amoxicillin 250mg', 12.00, 30),
 ('Ibuprofen 200mg',   4.75, 20),
 ('ORS Sachet',        3.00, 15);
CALL pr_record_sale(1, 10, CURRENT_DATE - 1);
CALL pr_record_sale(1, 20, CURRENT_DATE - 1);
CALL pr_record_sale(2,  5, CURRENT_DATE - 1);
CALL pr_record_sale(3,  8, CURRENT_DATE);
CALL pr_record_sale(3,  4, CURRENT_DATE);
CALL pr_record_sale(4,  3, CURRENT_DATE);

-- (e) View
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines WHERE stock_qty < 10;

-- (f) Index: equality column first, range column second
CREATE INDEX idx_sales_medicine_sold_on ON sales(medicine_id, sold_on);

-- (g) Refresh procedure (idempotent: recomputes from sales and overwrites)
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_sales(sales_date, total_qty, total_amount)
  SELECT p_day, COALESCE(SUM(quantity),0), COALESCE(SUM(quantity*unit_price),0)
  FROM sales WHERE sold_on = p_day
  ON CONFLICT (sales_date) DO UPDATE
    SET total_qty = EXCLUDED.total_qty, total_amount = EXCLUDED.total_amount;
END $$;

SELECT cron.schedule('refresh-daily-sales', '15 0 * * *',
                     $$CALL pr_refresh_sales(CURRENT_DATE - 1)$$);

---------------------------- TESTS / EVIDENCE ----------------------------
SELECT fn_sale_value(1, 4);                                   -- 10.00
DO $$ BEGIN PERFORM fn_sale_value(99, 1);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_sale_value(1, 0);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_sale(3, 500, CURRENT_DATE);        -- oversell
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT * FROM medicines ORDER BY 1;                           -- unchanged by failed sale
SELECT * FROM stock_audit ORDER BY audit_id;
UPDATE medicines SET medicine_name = 'Paracetamol 500 mg' WHERE medicine_id = 1; -- no audit row
SELECT * FROM v_low_stock;                                    -- Ibuprofen (8 left)
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);                      -- rerun: no double count
SELECT * FROM daily_sales;
SET enable_seqscan = off;  -- only because the demo table is tiny
EXPLAIN SELECT * FROM sales
WHERE medicine_id = 1 AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;
SELECT jobid, jobname, schedule, command FROM cron.job;
SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;
