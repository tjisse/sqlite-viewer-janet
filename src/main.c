#define _GNU_SOURCE
#include <janet.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>

int main(int argc, char **argv) {
    char executable[PATH_MAX], appdir[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", executable, sizeof(executable)-1);
    if (n < 0) return 1;
    executable[n] = 0;
    char *slash = strrchr(executable, '/');
    if (!slash) return 1;
    *slash = 0;
    if (strlen(executable) + sizeof("/../lib/sqlite-viewer") > sizeof(appdir)) return 1;
    strcpy(appdir, executable);
    strcat(appdir, "/../lib/sqlite-viewer");
    if (!getenv("SV_APP_DIR")) setenv("SV_APP_DIR", appdir, 1);
    janet_init();
    JanetTable *env = janet_core_env(NULL);
    JanetArray *args = janet_array(argc);
    for (int i=0; i<argc; ++i) janet_array_push(args, janet_cstringv(argv[i]));
    janet_def(env, "app-args", janet_wrap_array(args), "Process arguments");
    const char *boot =
      "(def app-dir (os/getenv \"SV_APP_DIR\")) "
      "(array/insert module/paths 0 [(string app-dir \"/modules/:all:.so\") :native (fn [x] x)]) "
      "(array/insert module/paths 0 [(string app-dir \"/modules/:all:/init.janet\") :source (fn [x] x)]) "
      "(array/insert module/paths 0 [(string app-dir \"/modules/:all:.janet\") :source (fn [x] x)]) "
      "(array/insert module/paths 0 [(string app-dir \"/:all:.janet\") :source (fn [x] x)]) "
      "(setdyn :args app-args) (import server) (server/main app-args)";
    Janet out;
    int result = janet_dostring(env, boot, "bootstrap", &out);
    if (!result) janet_loop();
    janet_deinit();
    return result ? 1 : 0;
}
