#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
printf '%s  %s\n' 2837d87acf6ee0ba8e4e63765926c25a98d63883b02f88be194a86b81d3fd24a assets/datastar.js | sha256sum -c -
deps=${SV_DEPS_DIR:-$root/.build/deps}
prefix=$root/.build/prefix
mkdir -p "$deps" "$prefix" dist/bin dist/lib/sqlite-viewer/modules dist/lib/sqlite-viewer/assets dist/share/licenses
while read -r name repo revision; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  if [[ ! -d "$deps/$name/.git" ]]; then git clone "$repo.git" "$deps/$name"; fi
  if ! git -C "$deps/$name" cat-file -e "$revision^{commit}" 2>/dev/null; then git -C "$deps/$name" fetch origin "$revision"; fi
  git -C "$deps/$name" checkout --quiet "$revision"
  [[ "$(git -C "$deps/$name" rev-parse HEAD)" == "$revision" ]]
  for license in LICENSE LICENSE.txt COPYING; do
    if [[ -f "$deps/$name/$license" ]]; then cp "$deps/$name/$license" "dist/share/licenses/$name-$license"; fi
  done
done < deps.lock
jobs=${JOBS:-4}
make -C "$deps/janet" -j"$jobs"
cmake -S "$deps/jansson" -B .build/jansson -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib -DJANSSON_BUILD_SHARED_LIBS=OFF -DJANSSON_BUILD_DOCS=OFF -DJANSSON_WITHOUT_TESTS=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON
cmake --build .build/jansson -j"$jobs"
cmake --install .build/jansson
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
cmake -S "$deps/libjwt" -B .build/libjwt -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DWITH_JSON_C=OFF -DWITH_GNUTLS=OFF -DWITH_OPENSSL=ON -DWITH_LIBCURL=OFF -DWITH_TESTS=OFF
cmake --build .build/libjwt -j"$jobs"
cmake --install .build/libjwt
modules=$root/dist/lib/sqlite-viewer/modules
cp -R "$deps/spork/spork" "$modules/"
cp -R "$deps/datastar-janet/datastar" "$modules/"
cp "$deps/datastar-janet/datastar.janet" "$modules/"
cp "$deps/jayson/src/jayson.janet" "$modules/"
mkdir -p "$modules/judge"
cp "$deps/judge/src/"*.janet "$modules/judge/"
cc -O2 -fPIC -shared -I"$deps/janet/build" "$deps/spork/src/json.c" -o "$modules/spork/json.so"
cc -O2 -fPIC -shared -I"$deps/janet/build" -I"$deps/sqlite3" src/sqlite-guard.c "$deps/sqlite3/sqlite3.c" -lm -ldl -lpthread -o "$modules/sqlite3.so"
cc -O2 -fPIC -shared -I"$deps/janet/build" $(pkg-config --cflags libjwt jansson) "$deps/janet-jwt/src/jwt.c" "$prefix/lib/libjwt.a" "$prefix/lib/libjansson.a" -lcrypto -lm -o "$modules/jwt.so"
cc -O2 -I"$deps/janet/build" src/main.c "$deps/janet/build/libjanet.a" -rdynamic -lm -ldl -lpthread -lrt -o dist/bin/sqlite-viewer
cp src/*.janet dist/lib/sqlite-viewer/
cp assets/* dist/lib/sqlite-viewer/assets/
cp deps.lock dist/share/licenses/deps.lock
cp LICENSE dist/share/licenses/sqlite-viewer-LICENSE
cp assets/datastar.LICENSE dist/share/licenses/datastar-browser-LICENSE
printf 'Built %s/dist/bin/sqlite-viewer\n' "$root"
