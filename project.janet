(declare-project
  :name "sqlite-viewer"
  :version "0.2.0"
  :description "A reactive SQLite viewer built entirely in Janet.")

# scripts/build.sh fetches exact revisions from deps.lock and builds crypto libs.
# No floating network dependency resolution takes place inside JPM.
(def deps (os/getenv "SV_DEPS_DIR" (string (os/cwd) "/.build/deps")))
(def prefix (string (os/cwd) "/.build/prefix"))

(def native-targets
  [(declare-native
     :name "sqlite3"
     :source [(string deps "/sqlite3/main.c") (string deps "/sqlite3/sqlite3.c")]
     :headers ["deps.lock" "project.janet" (string deps "/sqlite3/query-controls.c") (string deps "/sqlite3/sqlite3.h")]
     :lflags ["-lm" "-ldl" "-lpthread"])
   (declare-native
     :name "spork/json"
     :source [(string deps "/spork/src/json.c")]
     :headers ["deps.lock" "project.janet"])
   (declare-native
     :name "jwt"
     :source [(string deps "/janet-jwt/src/jwt.c")]
     :headers ["deps.lock" "project.janet" (string prefix "/lib/libjwt.a") (string prefix "/lib/libjansson.a")]
     :cflags [(string "-I" prefix "/include")]
     :lflags [(string prefix "/lib/libjwt.a") (string prefix "/lib/libjansson.a") "-lcrypto" "-lm"])])

(array/insert module/paths 0 ["src/:all:.janet" :source (fn [x] x)])

(def source-files
  (seq [folder :in ["src" "tests"]
        file :in (os/dir folder)
        :when (string/has-suffix? ".janet" file)]
    (string folder "/" file)))

(def inputs
  [;source-files "deps.lock" "project.janet"
   "assets/app.css" "assets/app.js" "assets/datastar.js" "assets/icon.svg"
   (string deps "/sqlite3/query-controls.c")
   ;(mapcat values native-targets)])

(declare-executable :name "sqlite-viewer" :entry "src/main.janet" :deps inputs)
(declare-executable :name "sqlite-viewer-tests" :entry "tests/core.janet" :deps inputs)
