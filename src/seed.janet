(import sqlite3 :as sql)
(defn script [conn text]
  (each statement (string/split ";" text)
    (unless (empty? (string/trim statement)) (sql/eval conn statement))))
(defn create [path]
  (when (os/stat path) (error "Seed destination already exists; refusing to overwrite"))
  (def conn (sql/open path))
  (defer (sql/close conn)
    (script conn `PRAGMA journal_mode=WAL;
      CREATE TABLE customers(id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT, plan TEXT, status TEXT, country TEXT, joined TEXT);
      CREATE INDEX customers_country ON customers(country);
      CREATE INDEX customers_plan ON customers(plan);
      CREATE TABLE orders(id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id), product TEXT, amount REAL, status TEXT, placed TEXT);
      CREATE TABLE products(id INTEGER PRIMARY KEY, name TEXT, category TEXT, price REAL, stock INTEGER);
      CREATE TABLE activity(id INTEGER PRIMARY KEY, event TEXT, occurred TEXT);
      CREATE VIEW active_customers AS SELECT * FROM customers WHERE status='Active';
      BEGIN;`)
    (def names ["Olivia Martin" "Liam Andersson" "Sofia Chen" "Noah Williams" "Emma Wilson" "Lucas Dubois" "Amelia Taylor" "Oliver Fischer" "Isabella Rossi" "Ethan Park" "Mia Garcia" "James Patel"])
    (loop [i :range [1 241]]
      (def name (names (% (dec i) (length names))))
      (sql/eval conn "INSERT INTO customers VALUES(?,?,?,?,?,?,?)"
        [i name (string "member" i "@example.com") ((if (= 0 (% i 4)) ["Enterprise"] ["Pro" "Free" "Pro"]) (% i (if (= 0 (% i 4)) 1 3)))
          (if (= 0 (% i 7)) "Invited" "Active") (["Netherlands" "Sweden" "Japan" "United States" "Germany" "France"] (% i 6)) (string "2026-08-" (string/format "%02d" (inc (% i 28))))])
      (sql/eval conn "INSERT INTO orders VALUES(?,?,?,?,?,?)" [i i "Workspace subscription" (* 9.5 (inc (% i 5))) "Paid" "2026-09-01"]))
    (script conn `INSERT INTO products VALUES(1,'Personal workspace','Subscription',9.5,1000),(2,'Team workspace','Subscription',29,500),(3,'Enterprise workspace','Subscription',99,100);
      INSERT INTO activity VALUES(1,'Demo database created','2026-09-06'); COMMIT;`))
  (print "Created demo database: " path))
