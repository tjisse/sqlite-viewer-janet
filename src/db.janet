(import sqlite3 :as sql)
(import watch)
(import sqlexpr :as expr)
(import query :as bounded)

(def quote-id expr/quote-id)

(defn query [database statement &opt params cap]
  (bounded/run (database :db) statement params cap))

(defn- query-expr [database form &opt cap]
  (def [statement params] (expr/format form))
  (query database statement params cap))

(defn tables [database]
  ((query-expr database
               {:select [:name :type] :from [:sqlite_schema]
                :where [:and [:in :type ["table" "view"]] [:not-like :name "sqlite_%"]]
                :order-by [[:name :asc]]} 1001) :rows))

(defn schema [database table]
  (query-expr database
              {:select [:cid :name :type [:as :notnull :required] [:as :dflt_value :default_value]
                        [:as :pk :primary_key] :hidden]
               :from [[:call :pragma_table_xinfo table]]} 257))

(defn indexes [database table]
  (query-expr database
              {:select [:name [:as :unique :is_unique] :origin :partial]
               :from [[:call :pragma_index_list table]]}))

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

(defn- contains-text [column value]
  [:> [:call :instr [:call :lower [:cast (expr/id column) :text]] [:call :lower value]] 0])

(defn- combine [op clauses]
  (if (= 1 (length clauses)) (first clauses) [op ;clauses]))

(defn data [database s]
  (def clauses @[])
  (when (not= "" (s :search))
    (array/push clauses (combine :or (map |(contains-text $ (s :search)) (s :columns)))))
  (when (not= "" (s :filter))
    (array/push clauses (if (= "contains" (s :op))
                          (contains-text (s :filter) (s :value))
                          [:= [:cast (expr/id (s :filter)) :text] (s :value)])))
  (def source @{:from [(expr/id (s :table))]})
  (unless (empty? clauses) (put source :where (combine :and clauses)))
  (def count-result (query-expr database (merge source {:select [[:call :count :*]]})))
  (def total (scan-number (((count-result :rows) 0) 0)))
  (def page (min (s :page) (max 1 (math/ceil (/ total (s :size))))))
  (put s :page page)
  (var visible (filter |(not (index-of $ (s :hidden))) (s :columns)))
  (when (empty? visible) (set visible (s :columns)))
  (def result (query-expr database
                          (merge source {:select (map expr/id visible)
                                         :order-by [[(expr/id (s :sort)) (keyword (s :direction))]]
                                         :limit (s :size) :offset (* (dec page) (s :size))})
                          (inc (s :size))))
  (put result :total total)
  (put s :total total)
  result)

(defn open [name path]
  (def connection (bounded/open path))
  @{:name name :db connection :watch (watch/attach connection)})
