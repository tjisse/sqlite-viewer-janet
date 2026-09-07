(import jwt)

(defn configure []
  (def issuer (os/getenv "SV_ISSUER"))
  (def audience (os/getenv "SV_AUDIENCE"))
  (def path (os/getenv "SV_JWKS"))
  (unless (and issuer audience path) (error "Set SV_ISSUER, SV_AUDIENCE and SV_JWKS, or explicitly use --demo"))
  (jwt/verifier :issuer issuer :audience audience :jwks (string (slurp path))
                :algorithms (string/split "," (os/getenv "SV_ALGORITHMS" "EdDSA"))))

(defn verify [verifier token]
  (unless (and (string? token) (<= (length token) 8192)) (error "Invalid session"))
  (def claims (jwt/verify verifier token))
  (unless (and (string? (claims "sub")) (> (length (claims "sub")) 0)) (error "Missing subject"))
  (unless (and (array? (claims "roles")) (index-of "viewer" (claims "roles"))) (error "Viewer permission required"))
  claims)

(defn permits? [claims database]
  (and (array? (claims "databases"))
       (or (index-of database (claims "databases")) (index-of "*" (claims "databases")))))

(defn token [req]
  (def headers (get req :headers @{}))
  (def bearer (headers "authorization"))
  (when (and (string? bearer) (string/has-prefix? "Bearer " bearer)) (break (string/slice bearer 7)))
  (def cookies (headers "cookie"))
  (var found nil)
  (when (string? cookies)
    (each part (string/split ";" cookies)
      (def p (string/trim part))
      (when (string/has-prefix? "sv_session=" p) (set found (string/slice p 11)))))
  found)
