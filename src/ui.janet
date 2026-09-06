(import db)
(import jayson)

(defn escape [value]
  (string/replace-all "'" "&#39;" (string/replace-all "\"" "&quot;"
    (string/replace-all ">" "&gt;" (string/replace-all "<" "&lt;"
      (string/replace-all "&" "&amp;" (string value)))))))
(defn enc [value]
  (def out @"")
  (each c (string/bytes (string value))
    (if (or (<= 48 c 57) (<= 65 c 90) (<= 97 c 122) (index-of c [45 46 95 126]))
      (buffer/push-byte out c)
      (buffer/format out "%%%02X" c)))
  (string out))
(defn url [q & changes]
  (def merged (merge q (apply struct changes)))
  (string "/?" (string/join (seq [[k v] :pairs merged :when (string? v)] (string (enc k) "=" (enc v))) "&")))
(defn link [text q & changes]
  (string "<a href=\"" (escape (apply url q changes)) "\">" (escape text) "</a>"))
(defn hidden [name value]
  (string "<input type=\"hidden\" name=\"" (escape name) "\" value=\"" (escape value) "\">"))
(defn option [value selected]
  (string "<option value=\"" (escape value) "\"" (if (= value selected) " selected" "") ">" (escape (if (= value "") "All columns" value)) "</option>"))
(defn cell [value]
  (cond
    (nil? value) "<span class=\"null\">NULL</span>"
    (buffer? value) (string "<span class=\"blob\">BLOB · " (length value) " bytes</span>")
    (string "<span title=\"" (escape value) "\">" (escape value) "</span>")))
(defn grid [result]
  (string "<div class=\"grid-scroll\" tabindex=\"0\" aria-label=\"Query results\"><table><thead><tr><th class=\"row-number\">#</th>"
    (string/join (map |(string "<th scope=\"col\">" (escape $) "</th>") (result :columns)))
    "</tr></thead><tbody>"
    (string/join (seq [[i row] :pairs (result :rows)]
      (string "<tr><td class=\"row-number\">" (inc i) "</td>"
        (string/join (map |(string "<td>" (cell $) "</td>") row)) "</tr>")))
    "</tbody></table>"
    (if (empty? (result :rows)) "<div class=\"empty\"><strong>No rows to show</strong><p>Try a different search or filter.</p></div>" "")
    "</div>"))
(defn result [database s q]
  (string "<section id=\"result\" class=\"result\" aria-label=\"Table contents\">"
    (if (nil? (s :table)) "<div class=\"empty\"><h2>This database has no tables</h2><p>Tables will appear here when they are created.</p></div>"
      (case (s :tab)
        "Schema" (string (grid (db/schema database (s :table))) "<footer>Column definitions · Primary key positions and generated columns</footer>")
        "Indexes" (string (grid (db/indexes database (s :table))) "<footer>Indexes defined on this table</footer>")
        "SQL" "<div class=\"empty\"><p>Run a query to see its results here.</p></div>"
        (do
          (def r (db/data database s))
          (string (grid r) "<footer><span>" (r :total) " rows · " (length (r :columns)) " visible columns</span><nav aria-label=\"Pagination\">"
            (if (> (s :page) 1) (link "‹ Previous" q "page" (string (dec (s :page)))) "<span class=\"disabled\">‹ Previous</span>")
            "<span>Page " (s :page) " of " (max 1 (math/ceil (/ (r :total) (s :size)))) "</span>"
            (if (< (* (s :page) (s :size)) (r :total)) (link "Next ›" q "page" (string (inc (s :page)))) "<span class=\"disabled\">Next ›</span>")
            "</nav></footer>")))) "</section>"))
(defn error-result [message]
  (string "<section id=\"result\" class=\"result\"><div class=\"empty error\" role=\"alert\"><h2>Couldn’t load these results</h2><p>" (escape message) "</p><p>Try a narrower query or reload the table.</p></div></section>"))
(defn table-list [database selected]
  (def rows (db/tables database))
  (string "<div id=\"table-list\"><div class=\"section-label\">TABLES <span>" (length rows) "</span></div><nav aria-label=\"Tables\">"
    (string/join (map (fn [t] (string "<a class=\"table-link " (if (= (first t) selected) "selected" "") "\" href=\""
      (escape (url {"db" (database :name)} "table" (first t))) "\"><span aria-hidden=\"true\">▦</span>" (escape (first t)) "</a>")) rows))
    "</nav></div>"))
(defn meta [database s]
  (string "<p id=\"table-meta\">" (if (s :total) (string (s :total) " rows <span>·</span> ") "")
    (length (s :columns)) " columns <span>·</span> " (escape (database :name)) "</p>"))
(defn shell [body]
  (string "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>SQLite Viewer</title><link rel=\"icon\" href=\"/assets/icon.svg\"><link rel=\"stylesheet\" href=\"/assets/app.css\"><script type=\"module\" src=\"/assets/datastar.js\"></script><script defer src=\"/assets/app.js\"></script></head><body>" body "</body></html>"))
(defn login [&opt message]
  (shell (string "<main class=\"login\"><div class=\"app-icon\">▦</div><h1>SQLite Viewer</h1><p>Sign in with an access token from your trusted identity provider.</p>"
    (if message (string "<p class=\"error\" role=\"alert\">" (escape message) "</p>") "")
    "<form method=\"post\" action=\"/session\"><label for=\"token\">Access token</label><textarea id=\"token\" name=\"token\" required autocomplete=\"off\" spellcheck=\"false\"></textarea><button class=\"primary\">Sign in</button></form><small>Your token stays in an HttpOnly session cookie.</small></main>")))
(defn page [database databases s q demo]
  (def name (database :name))
  (def all-tables (db/tables database))
  (def base @{"db" name "table" (s :table)})
  (def rendered (protect (result database s q)))
  (shell (string "<div class=\"workspace\"><aside><div class=\"brand\"><span class=\"app-icon\">▦</span><strong>SQLite Viewer</strong></div>"
    "<form method=\"get\" class=\"database-picker\"><label for=\"database\">DATABASE</label><select id=\"database\" name=\"db\" data-autosubmit>"
    (string/join (map |(option $ name) databases)) "</select><noscript><button>Open</button></noscript></form>"
    (table-list database (s :table))
    "<div class=\"sidebar-bottom\"><div class=\"connection\"><i></i> " (if demo "Demo database" "Read-only connection") "</div>"
    (if demo "<small>Sample data · Local access</small>" "<form method=\"post\" action=\"/logout\"><button>Sign out</button></form>")
    "</div></aside><main class=\"main\"><header><div><div class=\"breadcrumb\">" (escape name) " <span>/</span> Tables</div><h1><span class=\"table-icon\">▦</span> "
    (escape (or (s :table) "Database")) "</h1>" (meta database s) "</div><span id=\"live\" class=\"live\">" (if (= "SQL" (s :tab)) "● Ready" "● Connecting") "</span></header>"
    "<nav class=\"segments\" aria-label=\"Table views\">"
    (string/join (map |(string "<a class=\"" (if (= $ (s :tab)) "active" "") "\" "
      (if (= $ (s :tab)) "aria-current=\"page\" " "") "href=\"" (escape (url q "tab" $ "page" "1")) "\">" $ "</a>") ["Data" "Schema" "Indexes" "SQL"])) "</nav>"
    (if (= "SQL" (s :tab))
      (string "<form class=\"sql-editor\" data-signals=\"" (escape (jayson/encode @{:sql (string "SELECT * FROM " (db/quote-id (or (s :table) "sqlite_schema")) " LIMIT 100")}))
        "\" data-on:submit__prevent=\"@post('/query?db=" (enc name) "')\"><label for=\"sql\">SQL query</label><textarea id=\"sql\" data-bind:sql spellcheck=\"false\"></textarea><div><span>Read-only · Up to 200 rows · 250 ms budget</span><button class=\"primary\">▶ Run query</button></div></form>")
      (string "<form class=\"toolbar\" method=\"get\">" (hidden "db" name) (hidden "table" (s :table)) (hidden "tab" (s :tab))
        "<label class=\"search\"><span aria-hidden=\"true\">⌕</span><input name=\"search\" placeholder=\"Search this table\" aria-label=\"Search this table\" value=\"" (escape (s :search)) "\"></label>"
        "<details><summary>☷ Filter</summary><div class=\"popover\"><label>Column<select name=\"filter\">" (option "" (s :filter)) (string/join (map |(option $ (s :filter)) (s :columns)))
        "</select></label><label>Condition<select name=\"op\">" (option "equals" (s :op)) (option "contains" (s :op)) "</select></label><label>Value<input name=\"value\" value=\"" (escape (s :value)) "\"></label><button class=\"primary\">Apply filter</button></div></details>"
        "<details><summary>↕ Sort</summary><div class=\"popover\"><label>Column<select name=\"sort\">" (string/join (map |(option $ (s :sort)) (s :columns))) "</select></label><label>Order<select name=\"direction\">" (option "asc" (s :direction)) (option "desc" (s :direction)) "</select></label><button class=\"primary\">Apply sort</button></div></details>"
        "<details><summary>▥ Columns</summary><div class=\"popover columns\">"
        (string/join (map |(string "<label><input type=\"checkbox\" data-column=\"" (escape $) "\"" (if (index-of $ (s :hidden)) "" " checked") ">" (escape $) "</label>") (s :columns)))
        (hidden "hidden" (get q "hidden" "")) "<button class=\"primary\">Apply columns</button></div></details>"
        "<label class=\"page-size\"><span class=\"sr-only\">Rows per page</span><select name=\"size\">" (string/join (map |(option $ (string (s :size))) ["10" "25" "50" "100" "200"])) "</select></label><button class=\"apply\">Apply</button>"
        "<a class=\"export\" href=\"/export" (escape (string/slice (url q) 1)) "\">↥ Export</a></form>"))
    (if (first rendered) (rendered 1) (error-result (rendered 1)))
    "<p class=\"footnote\">" (if (= "SQL" (s :tab)) "Run a query to subscribe to its results. ⌘/Ctrl + Enter to run." "Changes appear automatically. Your database stays read-only.") "</p>"
    (if (= "SQL" (s :tab)) "" (string "<div id=\"subscription\" data-init=\"@get('/events" (escape (string/slice (url q "db" name "table" (or (s :table) "")) 1)) "')\"></div>"))
    "</main></div>")))
