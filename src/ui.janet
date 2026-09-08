(import db)
(import jayson)
(import janet-html :as html)

# janet-html escapes text, but expects callers to escape attribute values.
# Omit false/nil attributes and encode true as an HTML boolean attribute.
(defn- safe-tree [node]
  (if (indexed? node)
    (if (and (keyword? (first node)) (dictionary? (get node 1)))
      [(first node)
       (tabseq [[k v] :pairs (node 1) :when v]
         k (if (true? v) "" (html/escape v)))
       ;(map safe-tree (drop 2 node))]
      (map safe-tree node))
    node))

(defn render [& nodes]
  (apply html/encode (map safe-tree nodes)))

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
  [:a {:href (apply url q changes)} text])

(defn hidden [name value]
  [:input {:type "hidden" :name name :value (string value)}])

(defn option [value selected]
  [:option {:value value :selected (= value selected)} (if (= value "") "All columns" value)])

(defn cell [value]
  (cond
    (nil? value) [:span {:class "null"} "NULL"]
    (buffer? value) [:span {:class "blob"} "BLOB · " (length value) " bytes"]
    [:span {:title value} value]))

(defn grid [result]
  [:div {:class "grid-scroll" :tabindex "0" :aria-label "Query results"}
   [:table
    [:thead [:tr [:th {:class "row-number"} "#"]
             (map |[:th {:scope "col"} $] (result :columns))]]
    [:tbody (seq [[i row] :pairs (result :rows)]
              [:tr [:td {:class "row-number"} (inc i)]
               (map |[:td (cell $)] row)])]]
   (when (empty? (result :rows))
     [:div {:class "empty"} [:strong "No rows to show"] [:p "Try a different search or filter."]])])

(defn result [database s q]
  [:section {:id "result" :class "result" :aria-label "Table contents"}
   (if (nil? (s :table))
     [:div {:class "empty"} [:h2 "This database has no tables"] [:p "Tables will appear here when they are created."]]
     (case (s :tab)
       "Schema" [(grid (db/schema database (s :table))) [:footer "Column definitions · Primary key positions and generated columns"]]
       "Indexes" [(grid (db/indexes database (s :table))) [:footer "Indexes defined on this table"]]
       "SQL" [:div {:class "empty"} [:p "Run a query to see its results here."]]
       (do
         (def r (db/data database s))
         [(grid r)
          [:footer
           [:span (r :total) " rows · " (length (r :columns)) " visible columns"]
           [:nav {:aria-label "Pagination"}
            (if (> (s :page) 1) (link "‹ Previous" q "page" (string (dec (s :page)))) [:span {:class "disabled"} "‹ Previous"])
            [:span "Page " (s :page) " of " (max 1 (math/ceil (/ (r :total) (s :size))))]
            (if (< (* (s :page) (s :size)) (r :total)) (link "Next ›" q "page" (string (inc (s :page)))) [:span {:class "disabled"} "Next ›"])]]])))])

(defn error-result [message]
  [:section {:id "result" :class "result"}
   [:div {:class "empty error" :role "alert"}
    [:h2 "Couldn’t load these results"] [:p (string message)] [:p "Try a narrower query or reload the table."]]])

(defn query-result [r truncated]
  [:section {:id "result" :class "result"} (grid r)
   [:footer (length (r :rows)) " rows" (when truncated " · Limited to 200 rows")]])

(defn live-status []
  [:span {:id "live" :class "live" :data-heartbeat (os/time)} "● Live"])

(defn expired-status []
  [:span {:id "live" :class "live expired"} "Session expired · Sign in again"])

(defn table-list [database selected]
  (def rows (db/tables database))
  [:div {:id "table-list"}
   [:div {:class "section-label"} "TABLES " [:span (length rows)]]
   [:nav {:aria-label "Tables"}
    (map (fn [t]
           [:a {:class (if (= (first t) selected) "table-link selected" "table-link")
                :href (url {"db" (database :name)} "table" (first t))}
            [:span {:aria-hidden "true"} "▦"] (first t)]) rows)]])

(defn meta [database s]
  [:p {:id "table-meta"}
   (when (s :total) [(s :total) " rows " [:span "·"] " "])
   (length (s :columns)) " columns " [:span "·"] " " (database :name)])

(defn shell [body]
  (render (html/doctype :html5)
          [:html {:lang "en"}
           [:head
            [:meta {:charset "utf-8"}]
            [:meta {:name "viewport" :content "width=device-width,initial-scale=1"}]
            [:title "SQLite Viewer"]
            [:link {:rel "icon" :href "/assets/icon.svg"}]
            [:link {:rel "stylesheet" :href "/assets/app.css"}]
            [:script {:type "module" :src "/assets/datastar.js"}]
            [:script {:defer true :src "/assets/app.js"}]]
           [:body body]]))

(defn login [&opt message]
  (shell
    [:main {:class "login"}
     [:div {:class "app-icon"} "▦"] [:h1 "SQLite Viewer"]
     [:p "Sign in with an access token from your trusted identity provider."]
     (when message [:p {:class "error" :role "alert"} message])
     [:form {:method "post" :action "/session"}
      [:label {:for "token"} "Access token"]
      [:textarea {:id "token" :name "token" :required true :autocomplete "off" :spellcheck "false"}]
      [:button {:class "primary"} "Sign in"]]
     [:small "Your token stays in an HttpOnly session cookie."]]))

(defn- sql-editor [name s]
  [:form {:class "sql-editor"
          :data-signals (jayson/encode @{:sql (string "SELECT * FROM " (db/quote-id (or (s :table) "sqlite_schema")) " LIMIT 100")})
          :data-on:submit__prevent (string "@post('/query?db=" (enc name) "')")}
   [:label {:for "sql"} "SQL query"]
   [:textarea {:id "sql" :data-bind:sql true :spellcheck "false"}]
   [:div [:span "Read-only · Up to 200 rows · 250 ms budget"] [:button {:class "primary"} "▶ Run query"]]])

(defn- toolbar [name s q]
  [:form {:class "toolbar" :method "get"}
   (hidden "db" name) (hidden "table" (s :table)) (hidden "tab" (s :tab))
   [:label {:class "search"} [:span {:aria-hidden "true"} "⌕"]
    [:input {:name "search" :placeholder "Search this table" :aria-label "Search this table" :value (s :search)}]]
   [:details [:summary "☷ Filter"]
    [:div {:class "popover"}
     [:label "Column" [:select {:name "filter"} (option "" (s :filter)) (map |(option $ (s :filter)) (s :columns))]]
     [:label "Condition" [:select {:name "op"} (option "equals" (s :op)) (option "contains" (s :op))]]
     [:label "Value" [:input {:name "value" :value (s :value)}]]
     [:button {:class "primary"} "Apply filter"]]]
   [:details [:summary "↕ Sort"]
    [:div {:class "popover"}
     [:label "Column" [:select {:name "sort"} (map |(option $ (s :sort)) (s :columns))]]
     [:label "Order" [:select {:name "direction"} (option "asc" (s :direction)) (option "desc" (s :direction))]]
     [:button {:class "primary"} "Apply sort"]]]
   [:details [:summary "▥ Columns"]
    [:div {:class "popover columns"}
     (map |[:label [:input {:type "checkbox" :data-column $ :checked (nil? (index-of $ (s :hidden)))}] $] (s :columns))
     (hidden "hidden" (get q "hidden" ""))
     [:button {:class "primary"} "Apply columns"]]]
   [:label {:class "page-size"} [:span {:class "sr-only"} "Rows per page"]
    [:select {:name "size"} (map |(option $ (string (s :size))) ["10" "25" "50" "100" "200"])]]
   [:button {:class "apply"} "Apply"]
   [:a {:class "export" :href (string "/export" (string/slice (url q) 1))} "↥ Export"]])

(defn page [database databases s q demo]
  (def name (database :name))
  (def rendered (protect (result database s q)))
  (shell
    [:div {:class "workspace"}
     [:aside
      [:div {:class "brand"} [:span {:class "app-icon"} "▦"] [:strong "SQLite Viewer"]]
      [:form {:method "get" :class "database-picker"}
       [:label {:for "database"} "DATABASE"]
       [:select {:id "database" :name "db" :data-autosubmit true} (map |(option $ name) databases)]
       [:noscript [:button "Open"]]]
      (table-list database (s :table))
      [:div {:class "sidebar-bottom"}
       [:div {:class "connection"} [:i] " " (if demo "Demo database" "Read-only connection")]
       (if demo [:small "Sample data · Local access"]
         [:form {:method "post" :action "/logout"} [:button "Sign out"]])]]
     [:main {:class "main"}
      [:header
       [:div
        [:div {:class "breadcrumb"} name " " [:span "/"] " Tables"]
        [:h1 [:span {:class "table-icon"} "▦"] " " (or (s :table) "Database")]
        (meta database s)]
       [:span {:id "live" :class "live"} (if (= "SQL" (s :tab)) "● Ready" "● Connecting")]]
      [:nav {:class "segments" :aria-label "Table views"}
       (map |[:a {:class (if (= $ (s :tab)) "active" "")
                  :aria-current (when (= $ (s :tab)) "page")
                  :href (url q "tab" $ "page" "1")} $] ["Data" "Schema" "Indexes" "SQL"])]
      (if (= "SQL" (s :tab)) (sql-editor name s) (toolbar name s q))
      (if (first rendered) (rendered 1) (error-result (rendered 1)))
      [:p {:class "footnote"} (if (= "SQL" (s :tab))
                                "Run a query to subscribe to its results. ⌘/Ctrl + Enter to run."
                                "Changes appear automatically. Your database stays read-only.")]
      (when (not= "SQL" (s :tab))
        [:div {:id "subscription" :data-init (string "@get('/events" (string/slice (url q "db" name "table" (or (s :table) "")) 1) "')")}])]]))
