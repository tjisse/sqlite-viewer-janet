(import jwt)

(import https)

(defn fetch-jwks [issuer]
  (https/get (string issuer "/cdn-cgi/access/certs")))

(defn refresh! [context]
  (def now ((context :clock)))
  (when (or (context :refreshing) (< (- now (context :attempt)) 60)) (break false))
  (put context :attempt now)
  (put context :refreshing true)
  (def result (protect
                (jwt/verifier :issuer (context :issuer) :audience (context :audience)
                              :jwks ((context :fetch)) :algorithms ["RS256"])))
  (put context :refreshing false)
  (unless (first result)
    (eprint "Cloudflare key refresh failed; retaining cached keys")
    (break false))
  (put context :verifier (result 1))
  (put context :updated ((context :clock)))
  true)

(defn context [issuer audience fetch &opt clock]
  (def state @{:issuer issuer :audience audience :fetch fetch :clock (or clock os/time)
               :attempt (- math/inf) :updated (- math/inf) :refreshing false})
  (unless (refresh! state) (error "Unable to load trusted Cloudflare keys"))
  state)

(defn configure []
  (def issuer (os/getenv "SV_ISSUER"))
  (def audience (os/getenv "SV_AUDIENCE"))
  (unless (and (string? issuer)
               (peg/match ~{:main (sequence "https://" (some (set "abcdefghijklmnopqrstuvwxyz0123456789-"))
                                            ".cloudflareaccess.com" -1)} issuer)
               (string? audience) (> (length audience) 0))
    (error "Set SV_ISSUER=https://TEAM.cloudflareaccess.com and SV_AUDIENCE to the Access application AUD"))
  (def path (os/getenv "SV_JWKS"))
  (context issuer audience (if path (fn [] (string (slurp path))) (fn [] (fetch-jwks issuer)))))

(defn roles [claims]
  (def custom (claims "custom"))
  (def values (when (or (table? custom) (struct? custom)) (custom "roles")))
  (unless (and (array? values) (every? (map string? values))) (error "Missing or malformed Entra roles"))
  values)

(defn verify [context token]
  (unless (and (string? token) (< 0 (length token) 8193)) (error "Invalid Access assertion"))
  (when (>= (- ((context :clock)) (context :updated)) 3600) (refresh! context))
  (var checked (protect (jwt/verify (context :verifier) token)))
  # The native verifier deliberately exposes no unverified header or failure reason.
  # A verification failure (including unknown kid) can refresh at most once a minute.
  (unless (first checked)
    (unless (refresh! context) (error "Invalid Access assertion"))
    (set checked (protect (jwt/verify (context :verifier) token))))
  (unless (and (first checked) (< (- ((context :clock)) (context :updated)) 86400))
    (error "Invalid Access assertion or stale keys"))
  (def claims (checked 1))
  (unless (= "app" (claims "type")) (error "Access application token required"))
  (unless (and (string? (claims "sub")) (> (length (claims "sub")) 0)) (error "Missing subject"))
  (unless (index-of "sqlite-viewer.viewer" (roles claims)) (error "Viewer permission required"))
  claims)

(defn permits? [claims database]
  (def values (roles claims))
  (and (index-of "sqlite-viewer.viewer" values)
       (or (index-of (string "sqlite-viewer.db." database ".read") values)
           (index-of "sqlite-viewer.db.All.read" values))))

(defn token [req]
  (get-in req [:headers "cf-access-jwt-assertion"]))
