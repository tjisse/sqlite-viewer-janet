(import sqlite3 :as sql)
(import watch)

(defn quote-id [name]
  (string "\"" (string/replace-all "\"" "\"\"" name) "\""))
(defn query [database statement &opt params cap]
  (sql/safe-query (database :db) statement (or params []) (or cap 201)))
(defn tables [database]
  ((query database "SELECT name, type FROM sqlite_schema WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name" [] 1001) :rows))
(defn schema [database table]
  (query database "SELECT cid, name, type, \"notnull\" AS required, dflt_value AS default_value, pk AS primary_key, hidden FROM pragma_table_xinfo(?)" [table] 257))
(defn indexes [database table]
  (query database "SELECT name, \"unique\" AS is_unique, origin, partial FROM pragma_index_list(?)" [table]))
(defn columns [database table]
  (map |($ 1) ((schema database table) :rows)))
(defn integer [raw fallback low high]
  (def n (if (string? raw) (scan-number raw) raw))
  (if (and (number? n) (= n (math/floor n))) (min high (max low n)) fallback))
(defn short-text [raw]
  (unless (string? raw) (error "Expected a single text value"))
  (string/slice raw 0 (min 200 (length raw))))
(defn state [database q]
  (def names (map first (tables database)))
  (def selected (get q "table" (first names)))
  (unless (or (nil? selected) (index-of selected names)) (error "Unknown table"))
  (def cols (if selected (columns database selected) []))
  (def sorting (get q "sort" (first cols)))
  (unless (or (nil? sorting) (index-of sorting cols)) (error "Unknown sort column"))
  (def filter-col (get q "filter" ""))
  (unless (or (= filter-col "") (index-of filter-col cols)) (error "Unknown filter column"))
  (def hidden (string/split "," (get q "hidden" "")))
  @{:table selected :columns cols :sort sorting
    :direction (if (= "desc" (get q "direction")) "desc" "asc")
    :page (integer (get q "page") 1 1 100000) :size (integer (get q "size") 50 10 200)
    :search (short-text (get q "search" ""))
    :filter filter-col :value (short-text (get q "value" ""))
    :op (if (= "contains" (get q "op")) "contains" "equals")
    :hidden hidden :tab (get q "tab" "Data")})
(defn data [database s]
  (def clauses @[]) (def params @[])
  (when (not= "" (s :search))
    (array/push clauses (string "(" (string/join
      (map |(string "instr(lower(CAST(" (quote-id $) " AS TEXT)),lower(?))>0") (s :columns)) " OR ") ")"))
    (each c (s :columns) (array/push params (s :search))))
  (when (not= "" (s :filter))
    (array/push clauses (if (= "contains" (s :op))
      (string "instr(lower(CAST(" (quote-id (s :filter)) " AS TEXT)),lower(?))>0")
      (string "CAST(" (quote-id (s :filter)) " AS TEXT)=?")))
    (array/push params (s :value)))
  (def where (if (empty? clauses) "" (string " WHERE " (string/join clauses " AND "))))
  (def source (string " FROM " (quote-id (s :table)) where))
  (def count-result (query database (string "SELECT count(*)" source) params))
  (def total (scan-number (((count-result :rows) 0) 0)))
  (def page (min (s :page) (max 1 (math/ceil (/ total (s :size))))))
  (put s :page page)
  (var visible (filter |(not (index-of $ (s :hidden))) (s :columns)))
  (when (empty? visible) (set visible (s :columns)))
  (def result (query database (string "SELECT " (string/join (map quote-id visible) ",") source
    " ORDER BY " (quote-id (s :sort)) " " (s :direction)
    " LIMIT " (s :size) " OFFSET " (* (dec page) (s :size))) params (inc (s :size))))
  (put result :total total)
  (put s :total total)
  result)
(defn open [name path]
  (def connection (sql/readonly-open path))
  @{:name name :db connection :watch (watch/attach connection)})
