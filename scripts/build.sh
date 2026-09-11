#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
printf '%s  %s\n' 2837d87acf6ee0ba8e4e63765926c25a98d63883b02f88be194a86b81d3fd24a assets/datastar.js | sha256sum -c -
deps=${SV_DEPS_DIR:-$root/.build/deps}
prefix=$root/.build/prefix
mkdir -p "$deps" "$prefix" dist/bin .build/modules dist/share/licenses
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
modules=$root/.build/modules
cp -R "$deps/spork/spork" "$modules/"
cp -R "$deps/datastar-janet/datastar" "$modules/"
cp "$deps/datastar-janet/datastar.janet" "$modules/"
cp "$deps/jayson/src/jayson.janet" "$modules/"
cp "$deps/janet-html/src/janet-html.janet" "$modules/"
cp "$deps/janet-sqlexpr/src/sqlexpr.janet" "$modules/"
mkdir -p "$modules/judge"
cp "$deps/judge/src/"*.janet "$modules/judge/"
export SV_DEPS_DIR="$deps"
export JANET_PATH="$deps/jpm"
export JANET_HEADERPATH="$deps/janet/build" JANET_LIBPATH="$deps/janet/build"
export JANET_MODPATH="$modules" JANET_BUILDPATH="$root/.build/jpm"
export JANET_JPM_CONFIG="$root/scripts/jpm-config.janet"
"$deps/janet/build/janet" "$deps/jpm/jpm/cli.janet" --build-type=release build
cp .build/jpm/sqlite-viewer dist/bin/
cp deps.lock dist/share/licenses/deps.lock
cp LICENSE dist/share/licenses/sqlite-viewer-LICENSE
cp assets/datastar.LICENSE dist/share/licenses/datastar-browser-LICENSE
printf 'Built %s/dist/bin/sqlite-viewer\n' "$root"
