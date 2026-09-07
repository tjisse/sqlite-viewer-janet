(import sqlite3 :as sql)

# Hooks only record invalidation. Never run SQL, send SSE, or yield from them.
# A commit callback runs BEFORE durability. publish! is called after eval returns.

(defn attach [db]
  (def state @{:db db :pending @{} :committed @{} :all? false :version 0})
  (sql/update-hook db (fn [op database table rowid]
                        (put (state :pending) table true) nil))
  (sql/commit-hook db (fn []
                        (eachk table (state :pending) (put (state :committed) table true))
                        (table/clear (state :pending))
                        # Covers DDL, WITHOUT ROWID and DELETE truncation, which update-hook misses.
                        (put state :all? true)
                        nil))
  (sql/rollback-hook db (fn []
                          (table/clear (state :pending))
                          (table/clear (state :committed))
                          (put state :all? false)
                          nil))
  (put state :external ((first (sql/eval db "PRAGMA data_version")) :data_version))
  state)

(defn publish! [state]
  (when (or (state :all?) (> (length (state :committed)) 0))
    (put state :version (inc (state :version)))
    (table/clear (state :committed))
    (put state :all? false)
    true))

(defn eval! [state statement &opt params]
  (def result (protect (if params
                         (sql/eval-one (state :db) statement params)
                         (sql/eval-one (state :db) statement))))
  # eval-one prohibits multi-statements; a failed COMMIT invokes rollback-hook.
  (publish! state)
  (unless (first result) (error (result 1)))
  (result 1))

(defn poll! [state]
  (def version ((first (sql/eval (state :db) "PRAGMA data_version")) :data_version))
  (when (not= version (state :external))
    (put state :external version)
    (put state :version (inc (state :version)))
    true))

(defn detach [state]
  (sql/update-hook (state :db) nil)
  (sql/commit-hook (state :db) nil)
  (sql/rollback-hook (state :db) nil))
