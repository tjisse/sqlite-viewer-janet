(import server)

(defn main [& args]
  # An SSE client can disconnect during a write. Handle EPIPE in the adapter
  # instead of letting the operating system terminate the whole service.
  (os/sigaction :pipe (fn [&] nil))
  (server/main args))
