(import jurl)
(import jurl/native :as native)

# A deliberately narrow client for trusted key endpoints. Do not follow redirects
# or accept non-HTTPS protocols; enforce the cap while streaming, including when
# the server omits Content-Length. CA trust defaults to the system libcurl store.
(defn- get-blocking [url &opt ca-file]
  (unless (string/has-prefix? "https://" url) (error "HTTPS required"))
  (def output @"")
  (def result
    (jurl/request
      {:url url :method :get
       :options (merge {:protocols "https" :followlocation false
                        :ssl-verifypeer true :ssl-verifyhost 2
                        :connecttimeout-ms 3000 :timeout-ms 5000
                        :maxfilesize 1048576 :nosignal true}
                       (if ca-file {:cainfo ca-file} {}))
       :stream (fn [chunk]
                 (if (> (+ (length output) (length chunk)) 1048576)
                   0
                   (do (buffer/push output chunk) (length chunk))))}))
  # Clear native callback pointers before their Janet closures leave scope.
  (native/reset (result :handle))
  (unless (and (= :ok (result :error)) (= 200 (result :status)))
    (error "HTTPS key request failed"))
  (string output))

# Jurl uses libcurl's blocking easy API. A worker keeps key fetching from pausing
# HTTP requests or live subscriptions; only the result string crosses threads.
(defn get [url &opt ca-file]
  (def channel (ev/thread-chan 1))
  (ev/thread (fn [[channel url ca-file]]
               (ev/give channel (protect (get-blocking url ca-file))))
             [channel url ca-file])
  (def result (ev/take channel))
  (unless (first result) (error "HTTPS key request failed"))
  (result 1))
