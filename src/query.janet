(import sqlite3 :as sql)

# SQLite authorizer action codes. All unlisted actions are denied.
# Policy belongs here; the binding only exposes SQLite's controls.
(defn authorize [op arg1 arg2 database source]
  (case op
    21 :ok # SELECT
    33 :ok # RECURSIVE
    20 (if (or (nil? database) (= database "main")) :ok :deny) # READ
    31 (if (and arg2 (not (index-of arg2 ["load_extension" "readfile" "writefile"]))) :ok :deny)
    19 (if (index-of arg1 ["table_info" "table_xinfo" "index_list" "index_info" "data_version"]) :ok :deny)
    :deny))

(defn run [connection statement &opt params cap]
  (unless (and (string? statement) (<= (length statement) 16384))
    (error "SQL must be text of at most 16 KiB"))
  (default cap 201)
  (unless (and (int? cap) (<= 1 cap 1001)) (error "Invalid row limit"))
  (def start (os/clock))
  (var ticks 0)
  (sql/query connection statement (or params [])
             {:read-only true :integer-strings true
              :max-rows cap :max-bytes (* 4 1024 1024)
              :authorizer authorize :progress-steps 1000
              :progress (fn []
                          (++ ticks)
                          (or (> ticks 2000) (> (- (os/clock) start) 0.25)))}))

(defn open [path]
  (def connection (sql/open path :read-only))
  (def result
    (protect
      (sql/config connection :defensive true)
      (sql/config connection :trusted-schema false)
      (sql/allow-loading-extensions connection false)
      (sql/busy-timeout connection 100)
      (each [category value] [[:length 1048576] [:sql-length 16384] [:column 256] [:expr-depth 100]]
        (sql/limit connection category value))))
  (unless (first result)
    (sql/close connection)
    (error (result 1)))
  connection)
