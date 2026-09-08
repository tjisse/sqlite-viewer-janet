(import datastar :as ds)
(import datastar/adapter/spork :as adapter)
(import spork/http :as http)
(import spork/json :as json)
(import sqlite3 :as sql)
(import db)
(import auth)
(import ui)
(import watch)
(import seed)
(import assets)

(def databases @{})
(var verifier nil)
(var demo false)
(var origin "http://127.0.0.1:8080")
(var streams 0)

(defn response [status body &opt type headers]
  @{:status status :body body :headers (merge
                                         @{"Content-Type" (or type "text/html; charset=utf-8") "Cache-Control" "no-store"
                                           "X-Content-Type-Options" "nosniff" "Referrer-Policy" "no-referrer"
                                           "Content-Security-Policy" "default-src 'self'; script-src 'self' 'unsafe-eval'; style-src 'self'; img-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"}
                                         (or headers @{}))})

(defn body [req]
  (def size (get-in req [:headers "content-length"]))
  (unless (and (string? size) (scan-number size) (<= 0 (scan-number size) 20000)
               (not (get-in req [:headers "transfer-encoding"]))) (error "Body requires Content-Length, at most 20000 bytes"))
  (string (http/read-body req)))

(defn csrf? [req]
  (= origin (get-in req [:headers "origin"])))

(defn identity [req]
  (if demo @{"sub" "demo" "roles" @["viewer"] "databases" @["*"] "exp" (+ (os/time) 3600)}
    (auth/verify verifier (auth/token req))))

(defn csv-cell [value]
  (def text (cond (nil? value) "" (buffer? value) "[BLOB]" (string value)))
  # Mitigate spreadsheet formula execution for untrusted database cells.
  (def safe (if (and (> (length text) 0) (index-of (text 0) [61 43 45 64 9 13])) (string "'" text) text))
  (string "\"" (string/replace-all "\"" "\"\"" safe) "\""))

(defn events [req database s q claims]
  (when (>= streams 64) (break (response 503 "Too many live subscriptions" "text/plain")))
  (++ streams)
  (adapter/sse-response req
                        {:headers {"Cache-Control" "no-store" "X-Accel-Buffering" "no"}
                         :on-open (fn [gen]
                                    (ds/with-open-sse gen
                                                      (var seen -1)
                                                      (var heartbeat 0)
                                                      (while (and (gen :open?) (< (os/time) (claims "exp")))
                                                        (def version ((database :watch) :version))
                                                        (when (not= version seen)
                                                          (set seen version)
                                                          (when (not= "SQL" (s :tab))
                                                            (def r (protect
                                                                     (def fresh (db/state database q))
                                                                     (ui/render (ui/result database fresh q) (ui/meta database fresh) (ui/table-list database (fresh :table)))))
                                                            (ds/patch-elements gen (if (first r) (r 1) (ui/render (ui/error-result (r 1))))))
                                                          (ds/patch-elements gen (ui/render (ui/live-status))))
                                                        (when (= 0 (% heartbeat 15))
                                                          (ds/patch-elements gen (ui/render (ui/live-status))))
                                                        (++ heartbeat)
                                                        (ev/sleep 1))
                                                      (when (gen :open?)
                                                        (ds/patch-elements gen (ui/render (ui/expired-status))))))
                         :on-close (fn [gen] (-- streams))}))

(defn query-result [database statement]
  (def result (protect (db/query database statement [] 201)))
  (if (first result)
    (do (def r (result 1)) (def truncated (> (length (r :rows)) 200))
      (when truncated (array/pop (r :rows)))
      (ui/render (ui/query-result r truncated)))
    (ui/render (ui/error-result (result 1)))))

(defn query-stream [req database statement claims]
  (when (>= streams 64) (break (response 503 "Too many live subscriptions" "text/plain")))
  (++ streams)
  (def live? (= "true" (get-in req [:headers "datastar-request"])))
  (adapter/sse-response req
                        {:headers {"Cache-Control" "no-store" "X-Accel-Buffering" "no"}
                         :on-open (fn [gen]
                                    (ds/with-open-sse gen
                                                      (var seen -1) (var tick 0)
                                                      (while (and (gen :open?) (< (os/time) (claims "exp")))
                                                        (def version ((database :watch) :version))
                                                        (when (not= seen version)
                                                          (set seen version)
                                                          (ds/patch-elements gen (query-result database statement)))
                                                        (unless live? (break))
                                                        (when (= 0 (% tick 15)) (ds/patch-elements gen (ui/render (ui/live-status))))
                                                        (++ tick)
                                                        (ev/sleep 1))
                                                      (when (and live? (gen :open?))
                                                        (ds/patch-elements gen (ui/render (ui/expired-status))))))
                         :on-close (fn [gen] (-- streams))}))

(defn route [req]
  (def path (req :route))
  (def method (req :method))
  (when (= path "/healthz") (break (response 200 "ok\n" "text/plain")))
  (def authority (first (string/split "/" (string/slice origin (+ 3 (string/find "://" origin))))))
  (unless (= authority (get-in req [:headers "host"]))
    (break (response 403 "Host rejected" "text/plain")))
  (when (and (= method "GET") (index-of path ["/assets/app.css" "/assets/app.js" "/assets/datastar.js" "/assets/icon.svg"]))
    (break (response 200 (assets/files path)
                     (cond (string/has-suffix? ".css" path) "text/css" (string/has-suffix? ".svg" path) "image/svg+xml" "text/javascript"))))
  (when (= path "/session")
    (unless (= method "POST") (break (response 405 "Method not allowed" "text/plain")))
    (unless (csrf? req) (break (response 403 "Origin rejected" "text/plain")))
    (def form (first (peg/match http/query-string-grammar (body req))))
    (def token (get form "token"))
    (def checked (protect (auth/verify verifier token)))
    (unless (first checked) (break (response 401 (ui/login "The token is invalid, expired, or lacks viewer permission."))))
    (def cookie (string "sv_session=" token "; HttpOnly; SameSite=Strict; Path=/; Max-Age="
                        (math/floor (min 3600 (- ((checked 1) "exp") (os/time))))
                        (if (string/has-prefix? "https://" origin) "; Secure" "")))
    (break (response 303 "" nil {"Location" "/" "Set-Cookie" cookie})))
  (when (= path "/logout")
    (unless (and (= method "POST") (csrf? req)) (break (response 403 "Origin rejected" "text/plain")))
    (break (response 303 "" nil {"Location" "/" "Set-Cookie" "sv_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0"})))
  (def checked (protect (identity req)))
  (unless (first checked) (break (response 401 (ui/login))))
  (def claims (checked 1))
  (def allowed (sort (filter |(auth/permits? claims $) (keys databases))))
  (when (empty? allowed) (break (response 403 "No database access" "text/plain")))
  (def q (get req :query @{}))
  (def name (get q "db" (first allowed)))
  (unless (and (string? name) (index-of name allowed)) (break (response 403 "Database access denied" "text/plain")))
  (def database (databases name))
  (when (= path "/query")
    (unless (= method "POST") (break (response 405 "Method not allowed" "text/plain")))
    (unless (csrf? req) (break (response 403 "Origin rejected" "text/plain")))
    (def signals (json/decode (body req)))
    (break (query-stream req database (signals "sql") claims)))
  (unless (= method "GET") (break (response 405 "Method not allowed" "text/plain")))
  (def s (db/state database q))
  (case path
    "/" (response 200 (ui/page database allowed s q demo))
    "/events" (events req database s q claims)
    "/export" (do
                (unless (s :table) (error "Select a table first"))
                (def r (db/data database s))
                (def rows @[(r :columns) ;(r :rows)])
                (response 200 (string/join (map |(string/join (map csv-cell $) ",") rows) "\r\n") "text/csv; charset=utf-8"
                          {"Content-Disposition" "attachment; filename=sqlite-viewer-page.csv"}))
    (response 404 "Not found" "text/plain")))

(defn app [req]
  (def result (protect (route req)))
  (if (first result) (result 1) (response 400 "Request could not be processed. Check the table, query, and request format." "text/plain")))

(defn main [args]
  (when (= "--version" (get args 1)) (print "sqlite-viewer 0.2.0") (break nil))
  (when (= "--seed" (get args 1)) (seed/create (get args 2 "demo.sqlite")) (break nil))
  (set demo (= "--demo" (get args 1)))
  (def host (os/getenv "SV_HOST" "127.0.0.1"))
  (def port (db/integer (os/getenv "SV_PORT") 8080 1024 65535))
  (set origin (os/getenv "SV_ORIGIN" (string "http://127.0.0.1:" port)))
  (when (and demo (not= host "127.0.0.1")) (error "Demo mode binds only to 127.0.0.1"))
  (when (and (not demo) (not (string/has-prefix? "https://" origin))
             (not (and (= host "127.0.0.1") (= "1" (os/getenv "SV_ALLOW_HTTP")))))
    (error "Set an HTTPS SV_ORIGIN (or SV_ALLOW_HTTP=1 for local auth testing)"))
  (if demo
    (do (def path (os/getenv "SV_DEMO_DB" "demo.sqlite"))
      (unless (os/stat path) (seed/create path))
      (put databases "Studio" (db/open "Studio" path)))
    (do (set verifier (auth/configure))
      (def config (json/decode (slurp (os/getenv "SV_DATABASES"))))
      (eachp [name path] config (put databases name (db/open name path)))))
  (when (empty? databases) (error "Configure at least one database"))
  (ev/go (fn [] (while true
                  (each database (values databases) (protect (watch/poll! (database :watch))))
                  (ev/sleep 1))))
  (adapter/server app host port)
  (print "SQLite Viewer listening on http://" host ":" port)
  (flush))
