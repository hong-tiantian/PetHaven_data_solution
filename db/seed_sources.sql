-- =====================================================================
-- PetHaven Group - synthetic data for the three UC1 source systems
-- (Supabase / PostgreSQL). Load AFTER db/schema.sql.
--
-- Load with:  python scripts/load_seed.py
--
-- WHAT THIS FILE DOES
--   Empties every src_ table and reloads it, so it is safe to re-run.
--   All values are fixed (no random()), so every run gives the same data
--   and the later MDM / warehouse results can be checked exactly.
--
-- TWO KINDS OF DATA
--   A. Scenario customers (hand written). Each one reproduces a UC1 problem
--      from the report. The later MDM layer must resolve them:
--
--      Real person      POS            DIGITAL   GROOMING      UC1 problem shown
--      ---------------  -------------  --------  ------------  ---------------------------------
--      Emma Wilson      P1001          501       G01           1 same person, 3 IDs, 3 formats
--      Liam Chen        P1002 + P1015  502       G02           1 duplicate INSIDE POS as well
--      Olivia Nguyen    -              503       G03           2 pet Bella spelt two ways
--      Ava Patel        P1004          504       G04           3 new email online, old email at salon
--      Sophie Taylor    P1005          505       -             3 phone changed; only name+postcode match
--      James Lee (x2)   P1006          506       -             NEGATIVE test: two different people
--      Ethan Jones      P1007          508       (pet only)    2 salon pet Buddy has no owner record
--      Mia Kim          P1008          507       G06           1 email / name case differences
--      Chloe Martin     -              -         G07 + G08     1 duplicate INSIDE grooming, pet Daisy x2
--      Jack Brown       -              -         G05           4 care notes + 'Staffy' breed slang
--      Noah Smith       P1003          -         -             single-source control case
--      Lucas Garcia     -              509       -             single-source control case
--      (unknown)        -              -         pet Ghost     2 orphan pet, no owner at all
--
--   B. Background customers (generated, deterministic): single-source
--      customers with unique emails and phones, so they never match anyone.
--      They give the reports realistic volume.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Empty all source tables (children first is handled by CASCADE)
-- ---------------------------------------------------------------------
truncate table
  public.src_pos_sale_lines, public.src_pos_sales, public.src_pos_loyalty_members, public.src_pos_stores,
  public.src_digital_order_lines, public.src_digital_orders, public.src_digital_pets, public.src_digital_customers,
  public.src_grooming_appointments, public.src_grooming_pets, public.src_grooming_services, public.src_grooming_clients
restart identity cascade;


-- =====================================================================
-- SRC_POS
-- =====================================================================

-- Stores --------------------------------------------------------------
insert into public.src_pos_stores (store_id, store_code, store_name, suburb, state, postcode) values
  (1, 'S01', 'PetHaven Parramatta',   'Parramatta',   'NSW', '2150'),
  (2, 'S02', 'PetHaven Sydney CBD',   'Sydney',       'NSW', '2000'),
  (3, 'S03', 'PetHaven Marrickville', 'Marrickville', 'NSW', '2204');

-- A. Scenario loyalty members ------------------------------------------
-- Name is one field typed at the till; phone in any format; email optional.
insert into public.src_pos_loyalty_members
  (member_no, full_name, phone, email, postcode, loyalty_tier, registered_store_id, registered_at, updated_at) values
  ('P1001', 'EMMA WILSON',   '0412 345 678',    null,                      '2150', 'gold',   1, '2024-03-02 10:15+11', '2025-11-10 12:00+11'),
  ('P1002', 'Liam Chen',     '0423111222',      'liam.chen@outlook.com',   '2000', 'silver', 2, '2024-05-18 16:40+10', '2026-02-01 09:30+11'),
  ('P1003', 'Noah Smith',    '0401 555 666',    'noah.smith@yahoo.com',    '2010', 'bronze', 2, '2024-07-09 11:05+10', '2024-07-09 11:05+10'),
  ('P1004', 'Ava Patel',     '+61 430 123 456', null,                      '2140', 'silver', 1, '2024-08-21 14:22+10', '2025-06-01 10:00+10'),
  ('P1005', 'Sophie Taylor', '0455 222 333',    null,                      '2037', 'bronze', 3, '2024-09-01 13:10+10', '2024-09-01 13:10+10'),
  ('P1006', 'James Lee',     '0400 000 111',    null,                      '2000', 'bronze', 2, '2024-10-12 17:45+11', '2024-10-12 17:45+11'),
  ('P1007', 'ETHAN JONES',   '0477 888 999',    'Ethan.Jones@Gmail.com ',  '2150', 'gold',   1, '2024-11-30 09:50+11', '2026-01-15 15:20+11'),
  ('P1008', 'mia kim',       '0499321654',      null,                      '2204', 'bronze', 3, '2025-02-14 12:30+11', '2025-02-14 12:30+11'),
  -- Liam signed up again at the same store with an initial only: duplicate INSIDE POS
  ('P1015', 'L Chen',        '0423-111-222',    null,                      '2000', 'bronze', 2, '2025-08-20 18:05+10', '2025-08-20 18:05+10');

-- B. Background loyalty members P2001-P2024 (POS only, unique phone/email)
insert into public.src_pos_loyalty_members
  (member_no, full_name, phone, email, postcode, loyalty_tier, registered_store_id, registered_at, updated_at)
select
  'P' || (2000 + g),
  (array['Oliver','Charlotte','Jack','Amelia','William','Isla','Henry','Grace'])[1 + (g - 1) % 8] || ' ' ||
  (array['Harris','Clarke','Walker','Young','King','Wright','Scott','Baker','Hill','Green','Adams','Nelson'])[1 + (g - 1) % 12],
  '0450 ' || lpad((100 + g)::text, 3, '0') || ' ' || lpad((500 + g)::text, 3, '0'),
  case when g % 3 = 0 then null else 'pos.member' || g || '@example.com' end,     -- a third have no email
  (array['2150','2000','2204','2145','2010','2042'])[1 + g % 6],
  (array['bronze','bronze','silver','gold'])[1 + g % 4],
  1 + g % 3,
  timestamptz '2024-01-10 10:00+11' + (g * interval '17 days'),
  timestamptz '2024-01-10 10:00+11' + (g * interval '17 days')
from generate_series(1, 24) as g;

-- POS sales -----------------------------------------------------------
-- A. Scenario sales (sale_id 1-30). member_no null = walk-in (cannot be
--    linked to anyone, even after MDM).
insert into public.src_pos_sales (sale_id, store_id, member_no, sold_at, payment_method) values
  ( 1, 1, 'P1001', '2025-01-11 10:20+11', 'card'),
  ( 2, 1, 'P1001', '2025-03-08 11:05+11', 'card'),
  ( 3, 1, 'P1001', '2025-07-19 15:40+10', 'eftpos'),
  ( 4, 1, 'P1001', '2026-02-21 09:55+11', 'card'),
  ( 5, 2, 'P1002', '2025-02-02 12:30+11', 'card'),
  ( 6, 2, 'P1002', '2025-06-14 17:10+10', 'cash'),
  ( 7, 2, 'P1015', '2025-09-03 18:20+10', 'card'),     -- Liam's duplicate member number
  ( 8, 2, 'P1015', '2026-01-24 13:45+11', 'eftpos'),
  ( 9, 2, 'P1003', '2025-04-12 10:10+10', 'cash'),
  (10, 2, 'P1003', '2026-05-30 11:25+10', 'card'),
  (11, 1, 'P1004', '2025-05-17 14:00+10', 'card'),
  (12, 1, 'P1004', '2026-03-07 10:30+11', 'card'),
  (13, 3, 'P1005', '2025-01-25 16:15+11', 'eftpos'),
  (14, 3, 'P1005', '2025-10-11 12:05+11', 'card'),
  (15, 2, 'P1006', '2025-03-29 17:35+11', 'cash'),
  (16, 2, 'P1006', '2026-04-18 12:50+10', 'card'),
  (17, 1, 'P1007', '2025-02-15 09:40+11', 'card'),
  (18, 1, 'P1007', '2025-08-09 11:15+10', 'card'),
  (19, 1, 'P1007', '2026-06-20 10:05+10', 'gift_card'),
  (20, 3, 'P1008', '2025-04-26 15:30+10', 'eftpos'),
  (21, 3, 'P1008', '2026-07-11 14:10+10', 'card'),
  (22, 1, null,    '2025-05-03 10:45+10', 'cash'),     -- walk-in
  (23, 2, null,    '2025-11-22 13:20+11', 'card'),     -- walk-in
  (24, 3, null,    '2026-08-08 16:55+10', 'eftpos');   -- walk-in

-- B. Background sales: 3 per background member (sale_id 101-172)
insert into public.src_pos_sales (sale_id, store_id, member_no, sold_at, payment_method)
select
  100 + (m - 1) * 3 + k,
  1 + (m + k) % 3,
  'P' || (2000 + m),
  timestamptz '2025-01-05 10:00+11' + ((m * 23 + k * 97) % 600) * interval '1 day' + (k * interval '2 hours'),
  (array['card','cash','eftpos','card'])[1 + (m + k) % 4]
from generate_series(1, 24) as m, generate_series(1, 3) as k;

select setval(pg_get_serial_sequence('public.src_pos_sales', 'sale_id'), (select max(sale_id) from public.src_pos_sales));
select setval(pg_get_serial_sequence('public.src_pos_stores', 'store_id'), (select max(store_id) from public.src_pos_stores));

-- POS sale lines: 1 to 3 lines per sale from a small POS product list
-- (products are out of UC1 scope; codes differ from the web SKUs on purpose)
insert into public.src_pos_sale_lines (sale_id, product_code, product_description, quantity, unit_price)
select
  s.sale_id,
  (array['POS-10001','POS-10002','POS-20001','POS-20002','POS-30001','POS-40001'])[1 + (s.sale_id + n) % 6],
  (array['Adult Dry Dog Food 15kg','Puppy Dry Food 3kg','Indoor Cat Food 4kg','Cat Litter 10L','Rope Toy Large','Flea & Tick Treatment'])[1 + (s.sale_id + n) % 6],
  1 + (s.sale_id + n) % 2,
  (array[109.99, 39.99, 54.99, 18.99, 14.99, 64.99])[1 + (s.sale_id + n) % 6]
from public.src_pos_sales s
cross join generate_series(1, 3) as n
where n <= 1 + s.sale_id % 3;


-- =====================================================================
-- SRC_DIGITAL
-- =====================================================================

-- A. Scenario accounts ---------------------------------------------------
-- Customers type their own details: email is required and usually current.
insert into public.src_digital_customers
  (account_id, email, first_name, last_name, mobile, postcode, created_at, updated_at, last_login_at) values
  (501, 'emma.wilson@gmail.com',  'Emma',   'Wilson', '+61412345678',    '2150', '2024-06-11 20:10+10', '2026-03-15 21:00+11', '2026-09-20 19:45+10'),
  (502, 'Liam.Chen@outlook.com',  'Liam',   'Chen',   '0423 111 222',    '2000', '2024-09-03 22:30+10', '2025-12-02 08:15+11', '2026-09-01 07:50+10'),
  (503, 'olivia.ng@gmail.com',    'Olivia', 'Nguyen', '0488 123 999',    '2204', '2024-10-19 19:05+11', '2025-10-19 19:05+11', '2026-08-30 21:10+10'),
  -- Ava changed her email online recently; the salon still has the old one
  (504, 'ava.p.new@hotmail.com',  'Ava',    'Patel',  '+61430123456',    '2140', '2024-12-01 18:00+11', '2026-08-20 20:30+10', '2026-09-25 18:15+10'),
  -- Sophie's online mobile is newer than the one in POS; only name + postcode match
  (505, 'sophie.t@icloud.com',    'Sophie', 'Taylor', '0466 777 888',    '2037', '2025-01-07 12:00+11', '2026-05-02 09:40+10', '2026-09-10 12:25+10'),
  -- A DIFFERENT James Lee: other email, phone and postcode. Must NOT be merged with P1006.
  (506, 'james.lee88@gmail.com',  'James',  'Lee',    '0433 999 888',    '2150', '2025-02-22 21:45+11', '2025-02-22 21:45+11', '2026-07-14 22:05+10'),
  (507, 'mia.kim@gmail.com',      'Mia',    'Kim',    '+61 499 321 654', '2204', '2025-03-30 16:20+11', '2025-11-05 10:00+11', '2026-09-18 16:40+10'),
  (508, 'ethan.jones@gmail.com',  'Ethan',  'Jones',  null,              '2150', '2025-04-18 08:55+10', '2025-04-18 08:55+10', '2026-06-01 09:00+10'),
  (509, 'lucas.garcia@proton.me', 'Lucas',  'Garcia', '0411 222 999',    '2000', '2025-06-06 19:30+10', '2025-06-06 19:30+10', '2026-09-27 20:00+10');

-- B. Background accounts 601-616 (digital only, unique email/phone)
insert into public.src_digital_customers
  (account_id, email, first_name, last_name, mobile, postcode, created_at, updated_at, last_login_at)
select
  600 + g,
  'web.customer' || g || '@example.com',
  (array['Zoe','Ethan','Ruby','Leo','Chloe','Max','Ella','Archie'])[1 + (g - 1) % 8],
  (array['Murphy','Kelly','Ryan','Evans','Turner','Mitchell','Carter','Ward'])[1 + (g * 3) % 8],
  '+61 460 ' || lpad((200 + g)::text, 3, '0') || ' ' || lpad((700 + g)::text, 3, '0'),
  (array['2150','2000','2204','2031','2065','2113'])[1 + g % 6],
  timestamptz '2024-05-01 20:00+10' + (g * interval '29 days'),
  timestamptz '2024-05-01 20:00+10' + (g * interval '29 days'),
  timestamptz '2026-09-01 20:00+10' - (g * interval '3 days')
from generate_series(1, 16) as g;

select setval(pg_get_serial_sequence('public.src_digital_customers', 'account_id'), (select max(account_id) from public.src_digital_customers));

-- Digital pets (registered by the customer: controlled species, free-text breed)
insert into public.src_digital_pets (pet_id, account_id, name, species, breed, birth_date, created_at, updated_at) values
  ( 1, 501, 'Max',    'dog',          'Golden Retriever',  '2020-06-01', '2024-06-11 20:20+10', '2024-06-11 20:20+10'),
  ( 2, 502, 'Luna',   'cat',          'Ragdoll',           '2021-02-14', '2024-09-03 22:40+10', '2024-09-03 22:40+10'),
  ( 3, 503, 'Bella',  'dog',          'Toy Poodle',        '2019-11-03', '2024-10-19 19:15+11', '2024-10-19 19:15+11'),
  ( 4, 504, 'Pepper', 'dog',          'Cavoodle',          '2022-04-10', '2024-12-01 18:10+11', '2024-12-01 18:10+11'),
  ( 5, 507, 'Coco',   'cat',          'British Shorthair', '2021-08-08', '2025-03-30 16:30+11', '2025-03-30 16:30+11'),
  ( 6, 508, 'Buddy',  'dog',          'Labrador',          '2018-05-05', '2025-04-18 09:05+10', '2025-04-18 09:05+10'),
  ( 7, 509, 'Oscar',  'small_animal', 'Mini Lop',          '2023-01-20', '2025-06-06 19:40+10', '2025-06-06 19:40+10');

-- Background pets: every second background account has one pet
insert into public.src_digital_pets (pet_id, account_id, name, species, breed, birth_date, created_at, updated_at)
select
  100 + g,
  600 + g,
  (array['Archie','Molly','Teddy','Rosie','Milo','Lola','Charlie','Ruby'])[1 + (g / 2) % 8],
  (array['dog','cat','dog','bird'])[1 + (g / 2) % 4],
  (array['Border Collie','Domestic Shorthair','Beagle','Budgerigar'])[1 + (g / 2) % 4],
  date '2018-01-15' + (g * 97),
  timestamptz '2024-05-01 20:30+10' + (g * interval '29 days'),
  timestamptz '2024-05-01 20:30+10' + (g * interval '29 days')
from generate_series(2, 16, 2) as g;

select setval(pg_get_serial_sequence('public.src_digital_pets', 'pet_id'), (select max(pet_id) from public.src_digital_pets));

-- Digital orders ----------------------------------------------------------
-- A. Scenario orders (account_id null = guest checkout, never linkable)
insert into public.src_digital_orders (order_no, account_id, ordered_at, status, delivery_method, pickup_store) values
  ('WEB-100001', 501,  '2025-02-10 20:15+11', 'fulfilled', 'delivery',          null),
  ('WEB-100002', 501,  '2025-09-28 21:40+10', 'fulfilled', 'click_and_collect', 'PetHaven Parramatta'),
  ('WEB-100003', 501,  '2026-08-02 19:05+10', 'fulfilled', 'delivery',          null),
  ('WEB-100004', 502,  '2025-04-05 07:55+11', 'fulfilled', 'delivery',          null),
  ('WEB-100005', 502,  '2026-03-18 08:20+11', 'cancelled', 'delivery',          null),
  ('WEB-100006', 503,  '2025-06-22 20:35+10', 'fulfilled', 'click_and_collect', 'Pethaven Marrickville'),  -- store typed in lower case 'h'
  ('WEB-100007', 503,  '2026-04-09 21:00+10', 'fulfilled', 'delivery',          null),
  ('WEB-100008', 504,  '2025-12-14 18:45+11', 'fulfilled', 'delivery',          null),
  ('WEB-100009', 504,  '2026-09-21 19:30+10', 'placed',    'click_and_collect', 'PetHaven Parramatta'),
  ('WEB-100010', 505,  '2026-05-02 09:50+10', 'fulfilled', 'delivery',          null),
  ('WEB-100011', 506,  '2025-07-07 22:10+10', 'fulfilled', 'delivery',          null),
  ('WEB-100012', 507,  '2025-11-05 10:10+11', 'fulfilled', 'click_and_collect', 'PetHaven Marrickville'),
  ('WEB-100013', 508,  '2025-10-30 07:45+11', 'fulfilled', 'delivery',          null),
  ('WEB-100014', 509,  '2026-01-19 20:25+11', 'fulfilled', 'delivery',          null),
  ('WEB-100015', null, '2025-08-16 13:00+10', 'fulfilled', 'delivery',          null),   -- guest
  ('WEB-100016', null, '2026-06-27 15:35+10', 'fulfilled', 'delivery',          null);   -- guest

-- B. Background orders: 2 per background account
insert into public.src_digital_orders (order_no, account_id, ordered_at, status, delivery_method, pickup_store)
select
  'WEB-2' || lpad(((g - 1) * 2 + k)::text, 5, '0'),
  600 + g,
  timestamptz '2025-01-20 20:00+11' + ((g * 31 + k * 113) % 580) * interval '1 day',
  (array['fulfilled','fulfilled','fulfilled','cancelled'])[1 + (g + k) % 4],
  case when (g + k) % 3 = 0 then 'click_and_collect' else 'delivery' end,
  case when (g + k) % 3 = 0 then (array['PetHaven Parramatta','PetHaven Sydney CBD','PetHaven Marrickville'])[1 + g % 3] end
from generate_series(1, 16) as g, generate_series(1, 2) as k;

-- Order lines: 1 to 2 lines per order from the web catalogue (SKUs differ from POS codes)
insert into public.src_digital_order_lines (order_no, sku, product_name, quantity, unit_price)
select
  o.order_no,
  (array['SKU-DF-015','SKU-PF-003','SKU-CF-004','SKU-CL-010','SKU-TY-RL','SKU-FT-M'])[1 + (length(o.order_no) + n + ascii(right(o.order_no, 1))) % 6],
  (array['Adult Dry Dog Food 15 kg','Puppy Food 3 kg','Indoor Cat Food 4 kg','Clumping Litter 10 L','Rope Toy (L)','Flea & Tick Medium Dog'])[1 + (length(o.order_no) + n + ascii(right(o.order_no, 1))) % 6],
  1 + n % 2,
  (array[104.99, 37.99, 52.99, 17.99, 12.99, 59.99])[1 + (length(o.order_no) + n + ascii(right(o.order_no, 1))) % 6]
from public.src_digital_orders o
cross join generate_series(1, 2) as n
where n <= 1 + ascii(right(o.order_no, 1)) % 2;


-- =====================================================================
-- SRC_GROOMING
-- =====================================================================

-- Service menu ------------------------------------------------------------
insert into public.src_grooming_services (service_code, service_name, base_price, duration_min) values
  ('SV01', 'Full Groom',        95.00, 90),
  ('SV02', 'Wash & Dry',        55.00, 45),
  ('SV03', 'Nail Clip',         20.00, 15),
  ('SV04', 'Cat Groom',        110.00, 90),
  ('SV05', 'De-shed Treatment', 75.00, 60);

-- A. Scenario clients (salon staff type the name in mixed formats) ---------
insert into public.src_grooming_clients (client_code, client_name, contact_no, email, postcode, created_at, updated_at) values
  ('G01', 'Wilson, Emma',  '0412-345-678', 'Emma.Wilson@Gmail.com', '2150', '2024-04-06 09:00+10', '2025-04-02 09:00+11'),
  ('G02', 'Chen, Liam',    '0423 111 222', null,                    '2000', '2024-08-10 10:30+10', '2024-08-10 10:30+10'),
  ('G03', 'Olivia Nguyen', '0488123999',   'olivia.ng@gmail.com',   '2204', '2024-11-02 11:15+11', '2024-11-02 11:15+11'),
  -- Ava's OLD email: survivorship must prefer the newer digital email
  ('G04', 'Patel, Ava',    '0430 123 456', 'ava.patel@yahoo.com',   '2140', '2024-09-14 13:45+10', '2024-10-01 13:45+10'),
  ('G05', 'Brown, Jack',   '0422 654 321', 'jackb@gmail.com',       '2204', '2025-01-18 08:40+11', '2025-01-18 08:40+11'),
  ('G06', 'Kim, Mia',      null,           'MIA.KIM@GMAIL.COM',     '2204', '2025-05-10 12:20+10', '2025-05-10 12:20+10'),
  ('G07', 'Martin, Chloe', '0444 101 202', 'chloe.m@gmail.com',     '2150', '2025-02-01 09:30+11', '2025-02-01 09:30+11'),
  -- Chloe created again by another salon: duplicate INSIDE grooming
  ('G08', 'Chloe Martin',  '0444101202',   null,                    '2150', '2025-09-13 10:10+10', '2025-09-13 10:10+10');

-- B. Background salon clients G101-G112 (grooming only)
insert into public.src_grooming_clients (client_code, client_name, contact_no, email, postcode, created_at, updated_at)
select
  'G' || (100 + g),
  case when g % 2 = 0
       then (array['Robinson','Lewis','Hall','Allen','Morris','Price'])[1 + (g / 2) % 6] || ', ' || (array['Hannah','Lucy','Sam','Ben','Kate','Tom'])[1 + g % 6]
       else (array['Hannah','Lucy','Sam','Ben','Kate','Tom'])[1 + g % 6] || ' ' || (array['Robinson','Lewis','Hall','Allen','Morris','Price'])[1 + (g / 2) % 6]
  end,
  '0470 ' || lpad((300 + g)::text, 3, '0') || ' ' || lpad((800 + g)::text, 3, '0'),
  case when g % 4 = 0 then null else 'salon.client' || g || '@example.com' end,
  (array['2150','2000','2204','2140'])[1 + g % 4],
  timestamptz '2024-06-01 09:00+10' + (g * interval '21 days'),
  timestamptz '2024-06-01 09:00+10' + (g * interval '21 days')
from generate_series(1, 12) as g;

-- Grooming pets --------------------------------------------------------------
-- A. Scenario pets: free-text species / breed, care notes only exist here
insert into public.src_grooming_pets
  (pet_code, client_code, pet_name, species, breed, birth_date, care_notes, owner_phone_note, created_at, updated_at) values
  ('GP01', 'G01', 'MAX',    'Canine', 'Golden Retriver',   '2020-06-01', 'Sensitive skin: hypoallergenic shampoo only', null, '2024-04-06 09:05+10', '2025-04-02 09:05+11'),
  ('GP02', 'G02', 'Milo',   'Dog',    'Cavoodle',          '2022-09-12', 'Nervous with dryers, use low setting',        null, '2024-08-10 10:35+10', '2024-08-10 10:35+10'),
  ('GP03', 'G02', 'Luna',   'Feline', 'Ragdoll',           '2021-02-14', 'Coat mats in winter, brush first',            null, '2024-08-10 10:40+10', '2024-08-10 10:40+10'),
  ('GP04', 'G03', 'Bella',  'dog',    'Poodle (Toy)',      null,         null,                                          null, '2024-11-02 11:20+11', '2024-11-02 11:20+11'),
  ('GP05', 'G04', 'Pepper', 'Dog',    'cavoodle',          '2022-04-10', null,                                          null, '2024-09-14 13:50+10', '2024-09-14 13:50+10'),
  ('GP06', 'G05', 'Rocky',  'Dog',    'Staffy',            '2019-03-03', 'Reactive to other dogs: muzzle, book last slot', null, '2025-01-18 08:45+11', '2025-01-18 08:45+11'),
  ('GP07', 'G06', 'Coco',   'Cat',    'british shorthair', '2021-08-08', 'Scratches during nail clips',                 null, '2025-05-10 12:25+10', '2025-05-10 12:25+10'),
  ('GP08', 'G07', 'Daisy',  'Dog',    'Maltese',           '2020-12-24', 'Tear staining: clean around eyes',            null, '2025-02-01 09:35+11', '2025-02-01 09:35+11'),
  ('GP09', 'G08', 'Daisy',  'dog',    'Maltese',           null,         null,                                          null, '2025-09-13 10:15+10', '2025-09-13 10:15+10'),
  -- Walk-in pet with NO client record: only the owner's phone was written down (Ethan Jones)
  ('GP10', null,  'Buddy',  'Dog',    'Lab',               null,         'Stiff hips: lift gently onto table',          '0477888999', '2025-06-07 10:00+10', '2025-06-07 10:00+10'),
  -- Orphan pet: no client and no phone. Cannot be linked by any rule.
  ('GP11', null,  'Ghost',  'Cat',    null,                null,         null,                                          null, '2025-08-23 14:30+10', '2025-08-23 14:30+10');

-- B. Background pets: one per background client
insert into public.src_grooming_pets
  (pet_code, client_code, pet_name, species, breed, birth_date, care_notes, owner_phone_note, created_at, updated_at)
select
  'GP' || (100 + g),
  'G' || (100 + g),
  (array['Bailey','Sasha','Rex','Nala','Toby','Maggie'])[1 + g % 6],
  (array['Dog','dog','Canine','Cat'])[1 + g % 4],
  (array['Shih Tzu','Labradoodle','Schnauzer','Persian'])[1 + g % 4],
  date '2017-06-01' + (g * 131),
  case when g % 3 = 0 then 'Does not like ears touched' end,
  null,
  timestamptz '2024-06-01 09:05+10' + (g * interval '21 days'),
  timestamptz '2024-06-01 09:05+10' + (g * interval '21 days')
from generate_series(1, 12) as g;

-- Appointments ------------------------------------------------------------------
-- salon_store names the store in the salon system's own words (not a POS key).
-- A. Scenario appointments
insert into public.src_grooming_appointments
  (pet_code, service_code, salon_store, appointment_at, groomer_name, status, price_charged, groomer_notes) values
  ('GP01', 'SV01', 'Parramatta Salon',   '2025-01-18 09:00+11', 'Kylie', 'completed', 95.00, 'Used oatmeal shampoo, no reaction'),
  ('GP01', 'SV01', 'Parramatta Salon',   '2025-04-12 09:00+10', 'Kylie', 'completed', 95.00, null),
  ('GP01', 'SV05', 'Parramatta Salon',   '2025-10-04 10:00+10', 'Priya', 'completed', 75.00, 'Heavy shedding'),
  ('GP01', 'SV01', 'Parramatta Salon',   '2026-10-10 09:00+11', 'Kylie', 'booked',    null,  null),
  ('GP02', 'SV02', 'CBD Salon',          '2025-03-01 11:00+11', 'Marco', 'completed', 55.00, 'Very anxious, took breaks'),
  ('GP02', 'SV01', 'CBD Salon',          '2025-09-20 11:00+10', 'Marco', 'no_show',   null,  null),
  ('GP02', 'SV01', 'CBD Salon',          '2026-02-14 11:00+11', 'Marco', 'completed', 95.00, null),
  ('GP03', 'SV04', 'CBD Salon',          '2025-07-05 13:00+10', 'Marco', 'completed', 110.00, 'Removed mats behind ears'),
  ('GP04', 'SV01', 'Marrickville Salon', '2025-02-22 10:00+11', 'Jess',  'completed', 95.00, null),
  ('GP04', 'SV03', 'Marrickville Salon', '2025-11-15 10:00+11', 'Jess',  'completed', 20.00, null),
  ('GP05', 'SV02', 'Parramatta Salon',   '2025-05-24 14:00+10', 'Priya', 'completed', 55.00, null),
  ('GP05', 'SV01', 'Parramatta Salon',   '2026-06-13 14:00+10', 'Priya', 'cancelled', null,  'Owner cancelled by phone'),
  ('GP06', 'SV01', 'Marrickville Salon', '2025-03-15 16:00+11', 'Jess',  'completed', 95.00, 'Muzzled, fine once calm'),
  ('GP06', 'SV01', 'Marrickville Salon', '2025-12-06 16:00+11', 'Tom',   'completed', 95.00, 'New groomer not told about reactivity'),
  ('GP07', 'SV03', 'Marrickville Salon', '2025-06-21 12:00+10', 'Jess',  'completed', 20.00, 'Scratched, used towel wrap'),
  ('GP07', 'SV04', 'Marrickville Salon', '2026-04-04 12:00+11', 'Jess',  'completed', 110.00, null),
  ('GP08', 'SV01', 'Parramatta Salon',   '2025-03-22 09:30+11', 'Kylie', 'completed', 95.00, null),
  ('GP09', 'SV02', 'Parramatta Salon',   '2025-09-27 09:30+10', 'Priya', 'completed', 55.00, 'Owner said she has been here before?'),
  ('GP10', 'SV02', 'Parramatta Salon',   '2025-06-07 10:00+10', 'Kylie', 'completed', 55.00, 'Walk-in, no client file'),
  ('GP10', 'SV01', 'Parramatta Salon',   '2026-01-17 10:00+11', 'Kylie', 'completed', 95.00, null),
  ('GP11', 'SV04', 'CBD Salon',          '2025-08-23 14:30+10', 'Marco', 'completed', 110.00, 'Owner details not recorded');

-- B. Background appointments: 2 per background pet
insert into public.src_grooming_appointments
  (pet_code, service_code, salon_store, appointment_at, groomer_name, status, price_charged, groomer_notes)
select
  'GP' || (100 + g),
  case when g % 4 = 3 then 'SV04' else (array['SV01','SV02','SV03','SV05'])[1 + (g + k) % 4] end,
  (array['Parramatta Salon','CBD Salon','Marrickville Salon'])[1 + g % 3],
  timestamptz '2025-01-10 09:00+11' + ((g * 37 + k * 151) % 560) * interval '1 day',
  (array['Kylie','Priya','Marco','Jess','Tom'])[1 + (g + k) % 5],
  case when (g + k) % 9 = 0 then 'no_show' else 'completed' end,
  case when (g + k) % 9 = 0 then null
       when g % 4 = 3 then 110.00
       else (array[95.00, 55.00, 20.00, 75.00])[1 + (g + k) % 4] end,
  null
from generate_series(1, 12) as g, generate_series(1, 2) as k;


-- =====================================================================
-- Summary: row counts per table (shown after loading)
-- =====================================================================
select 'src_pos_stores'            as table_name, count(*) as row_count from public.src_pos_stores
union all select 'src_pos_loyalty_members',   count(*) from public.src_pos_loyalty_members
union all select 'src_pos_sales',             count(*) from public.src_pos_sales
union all select 'src_pos_sale_lines',        count(*) from public.src_pos_sale_lines
union all select 'src_digital_customers',     count(*) from public.src_digital_customers
union all select 'src_digital_pets',          count(*) from public.src_digital_pets
union all select 'src_digital_orders',        count(*) from public.src_digital_orders
union all select 'src_digital_order_lines',   count(*) from public.src_digital_order_lines
union all select 'src_grooming_clients',      count(*) from public.src_grooming_clients
union all select 'src_grooming_pets',         count(*) from public.src_grooming_pets
union all select 'src_grooming_services',     count(*) from public.src_grooming_services
union all select 'src_grooming_appointments', count(*) from public.src_grooming_appointments;
