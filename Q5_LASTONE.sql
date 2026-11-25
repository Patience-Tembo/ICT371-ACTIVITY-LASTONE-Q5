-- ==========================================
-- ICT371 QUESTION 5: Hostel Room Allocation
-- ==========================================

-- Clean up existing tables
DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

-- ---------------------------------------------------------
-- (a) Database and seed data [6 marks]
-- ---------------------------------------------------------
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) UNIQUE NOT NULL,
  full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
  room_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  room_number VARCHAR(20) UNIQUE NOT NULL,
  capacity    INT NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
  allocation_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id    INT NOT NULL REFERENCES students(student_id),
  room_id       INT NOT NULL REFERENCES rooms(room_id),
  allocated_on  DATE NOT NULL,
  released_on   DATE NULL,
  status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE','ENDED')),
  -- ACTIVE requires released_on NULL; ENDED requires a release date
  CONSTRAINT chk_alloc_state CHECK (
    (status='ACTIVE' AND released_on IS NULL) OR
    (status='ENDED'  AND released_on IS NOT NULL)
  )
);

CREATE TABLE occupancy_snapshot (
  snapshot_date DATE NOT NULL,
  room_id       INT  NOT NULL REFERENCES rooms(room_id),
  occupied_beds INT NOT NULL,
  free_beds     INT NOT NULL,
  PRIMARY KEY (snapshot_date, room_id)
);

-- ---------------------------------------------------------
-- (b) Function [6 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT) RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE v_cap INT; v_active INT;
BEGIN
  SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room %', p_room_id; END IF;
  
  -- Ended allocations must not reduce availability
  SELECT COUNT(*) INTO v_active FROM allocations
   WHERE room_id = p_room_id AND status='ACTIVE';
   
  RETURN v_cap - v_active;
END $$;

-- ---------------------------------------------------------
-- (c) Procedure [8 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student'; END IF;
  
  PERFORM 1 FROM rooms WHERE room_id = p_room_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room'; END IF;
  
  -- Ensure student has no ACTIVE allocation
  IF EXISTS (SELECT 1 FROM allocations WHERE student_id=p_student_id AND status='ACTIVE') THEN
    RAISE EXCEPTION 'Student already has an ACTIVE allocation';
  END IF;
  
  -- Check availability
  IF fn_free_beds(p_room_id) <= 0 THEN RAISE EXCEPTION 'Room full'; END IF;
  
  -- Create ACTIVE allocation
  INSERT INTO allocations(student_id, room_id, allocated_on, released_on, status)
  VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END $$;

-- ---------------------------------------------------------
-- (d) Trigger [8 marks]
-- ---------------------------------------------------------
-- BEFORE INSERT OR UPDATE row trigger for capacity and one-ACTIVE rule
CREATE OR REPLACE FUNCTION trg_alloc_check() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_cap INT; v_count INT;
BEGIN
  IF NEW.status = 'ACTIVE' THEN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id;
    
    -- Check room capacity (exclude the row being updated)
    SELECT COUNT(*) INTO v_count FROM allocations
     WHERE room_id = NEW.room_id AND status='ACTIVE'
       AND allocation_id <> COALESCE(NEW.allocation_id, -1);
    IF v_count >= v_cap THEN RAISE EXCEPTION 'Room capacity exceeded'; END IF;

    -- Check one ACTIVE allocation per student (exclude the row being updated)
    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = NEW.student_id AND status='ACTIVE'
                 AND allocation_id <> COALESCE(NEW.allocation_id, -1)) THEN
      RAISE EXCEPTION 'Student already has an ACTIVE allocation';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_allocations_check 
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_alloc_check();

-- ---------------------------------------------------------
-- (e) View [5 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_number, r.capacity,
       COUNT(a.allocation_id) FILTER (WHERE a.status='ACTIVE') AS occupied,
       r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status='ACTIVE') AS free
FROM rooms r 
LEFT JOIN allocations a ON a.room_id = r.room_id
GROUP BY r.room_id, r.room_number, r.capacity;

-- ---------------------------------------------------------
-- (f) Index [5 marks]
-- ---------------------------------------------------------
CREATE INDEX idx_alloc_active_room ON allocations(room_id) WHERE status='ACTIVE';
-- EXPLAIN SELECT * FROM allocations WHERE room_id=1 AND status='ACTIVE';

-- ---------------------------------------------------------
-- (g) Scheduled job [6 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy() LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO occupancy_snapshot(snapshot_date, room_id, occupied_beds, free_beds)
  SELECT CURRENT_DATE, r.room_id,
         COUNT(a.allocation_id) FILTER (WHERE a.status='ACTIVE'),
         r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status='ACTIVE')
  FROM rooms r 
  LEFT JOIN allocations a ON a.room_id = r.room_id
  GROUP BY r.room_id, r.capacity
  ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;
END $$;

-- SELECT cron.schedule('hostel-daily','55 23 * * *',$$CALL pr_refresh_occupancy()$$);

-- ==========================================
-- SEED DATA & TESTING
-- ==========================================

-- 1. Insert students and rooms
INSERT INTO students(student_number, full_name) VALUES ('S001','Alice'), ('S002','Bob'), ('S003','Cara'), ('S004', 'Dan');
INSERT INTO rooms(room_number, capacity) VALUES ('R101', 2), ('R102', 3), ('R103', 2);

-- 2. Allocate rooms
CALL pr_allocate_room(1, 1, CURRENT_DATE);
CALL pr_allocate_room(2, 1, CURRENT_DATE); -- Room 1 is now FULL
CALL pr_allocate_room(3, 2, CURRENT_DATE); -- Room 2 is partially occupied

-- 3. Test one-ACTIVE-per-student rule (This SHOULD fail)
-- CALL pr_allocate_room(1, 2, CURRENT_DATE);

-- 4. End Bob's allocation (He leaves the hostel)
UPDATE allocations 
SET status = 'ENDED', released_on = CURRENT_DATE 
WHERE student_id = 2 AND status = 'ACTIVE';

-- 5. Allocate Bob to a new room (This should now succeed)
CALL pr_allocate_room(2, 3, CURRENT_DATE);

-- 6. Check the view (All rooms should be listed, even empty R103 before Bob moved)
SELECT * FROM v_room_occupancy;

-- 7. Run the occupancy snapshot and check results
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot;