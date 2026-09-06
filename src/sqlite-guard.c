/* Compile the pinned tjisse/sqlite3 binding unchanged, then extend its API.
 * All connection objects and ordinary eval operations remain upstream's.
 * This narrow adapter adds bounded read queries absent from that binding. */
#define JANET_ENTRY_NAME upstream_sqlite_init
#include <main.c>
#undef JANET_MODULE_ENTRY
#include <time.h>

typedef struct { int ticks; struct timespec start; } Budget;
static int progress(void *p) {
    Budget *b = p;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double seconds = now.tv_sec-b->start.tv_sec + (now.tv_nsec-b->start.tv_nsec)/1e9;
    return ++b->ticks > 2000 || seconds > 0.25;
}
static int authorize(void *p, int op, const char *a, const char *b, const char *db, const char *trigger) {
    (void)p; (void)trigger;
    switch (op) {
      case SQLITE_SELECT: case SQLITE_RECURSIVE: return SQLITE_OK;
      case SQLITE_READ: return (!db || !strcmp(db,"main")) ? SQLITE_OK : SQLITE_DENY;
      case SQLITE_FUNCTION:
        return b && strcmp(b,"load_extension") && strcmp(b,"readfile") && strcmp(b,"writefile") ? SQLITE_OK : SQLITE_DENY;
      case SQLITE_PRAGMA:
        return a && (!strcmp(a,"table_info") || !strcmp(a,"table_xinfo") || !strcmp(a,"index_list") || !strcmp(a,"index_info") || !strcmp(a,"data_version")) ? SQLITE_OK : SQLITE_DENY;
      default: return SQLITE_DENY;
    }
}
static Janet readonly_open(int32_t argc, Janet *argv) {
    janet_fixarity(argc,1);
    const char *path = (const char *)janet_getstring(argv,0);
    sqlite3 *conn = NULL;
    int rc = sqlite3_open_v2(path,&conn,SQLITE_OPEN_READONLY|SQLITE_OPEN_NOMUTEX,NULL);
    if (rc != SQLITE_OK) { if(conn) sqlite3_close(conn); janet_panic("Cannot open configured database read-only"); }
    sqlite3_db_config(conn,SQLITE_DBCONFIG_DEFENSIVE,1,NULL);
    sqlite3_db_config(conn,SQLITE_DBCONFIG_TRUSTED_SCHEMA,0,NULL);
    sqlite3_enable_load_extension(conn,0);
    sqlite3_busy_timeout(conn,100);
    sqlite3_limit(conn,SQLITE_LIMIT_LENGTH,1048576);
    sqlite3_limit(conn,SQLITE_LIMIT_SQL_LENGTH,16384);
    sqlite3_limit(conn,SQLITE_LIMIT_COLUMN,256);
    sqlite3_limit(conn,SQLITE_LIMIT_EXPR_DEPTH,100);
    Db *db = janet_abstract(&sql_conn_type,sizeof(Db));
    db->handle=conn; db->flags=0;
    db->update_cb=janet_wrap_nil(); db->commit_cb=janet_wrap_nil();
    db->rollback_cb=janet_wrap_nil(); db->hook_error=janet_wrap_nil();
    janet_gcroot(db->update_cb); janet_gcroot(db->commit_cb); janet_gcroot(db->rollback_cb);
    return janet_wrap_abstract(db);
}
static Janet safe_query(int32_t argc, Janet *argv) {
    janet_arity(argc,2,4);
    Db *db=janet_getabstract(argv,0,&sql_conn_type);
    if(db->flags & FLAG_CLOSED) janet_panic(MSG_DB_CLOSED);
    const uint8_t *query=janet_getstring(argv,1);
    int length=janet_string_length(query);
    if(length>16384 || has_null(query,length)) janet_panic("Invalid or oversized SQL");
    int cap=argc>3 ? janet_getinteger(argv,3) : 201;
    if(cap<1 || cap>1001) janet_panic("Invalid row limit");
    Budget budget={0}; clock_gettime(CLOCK_MONOTONIC,&budget.start);
    sqlite3_set_authorizer(db->handle,authorize,NULL);
    sqlite3_progress_handler(db->handle,1000,progress,&budget);
    sqlite3_stmt *stmt=NULL;
    const char *tail=NULL, *error=NULL;
    JanetArray *rows=janet_array(0), *columns=janet_array(0);
    int rc=sqlite3_prepare_v2(db->handle,(const char*)query,length,&stmt,&tail);
    if(rc!=SQLITE_OK) {error="Query rejected or exceeded its execution budget"; goto done;}
    if(!stmt || !sqlite3_stmt_readonly(stmt)) {error="Only a single read query is allowed"; goto done;}
    while(tail && (*tail==' ' || *tail=='\n' || *tail=='\r' || *tail=='\t')) ++tail;
    if(tail && *tail) {error="Only one SQL statement is allowed"; goto done;}
    if(argc>2 && (error=bindmany(stmt,argv[2]))) goto done;
    int ncols=sqlite3_column_count(stmt);
    for(int c=0;c<ncols;c++) janet_array_push(columns,janet_cstringv(sqlite3_column_name(stmt,c)));
    size_t bytes=0;
    while(rows->count<cap && (rc=sqlite3_step(stmt))==SQLITE_ROW) {
      JanetArray *row=janet_array(ncols);
      for(int c=0;c<ncols;c++) {
        bytes += sqlite3_column_bytes(stmt,c);
        if(bytes>4*1024*1024) {error="Result exceeds 4 MiB; select fewer or smaller columns"; goto done;}
        if(sqlite3_column_type(stmt,c)==SQLITE_INTEGER) {
          /* Preserve all 64 bits in a viewer instead of rounding through double. */
          janet_array_push(row,janet_cstringv((const char*)sqlite3_column_text(stmt,c)));
        } else janet_array_push(row,column_value(stmt,c));
      }
      janet_array_push(rows,janet_wrap_array(row));
    }
    if(rc!=SQLITE_DONE && rc!=SQLITE_ROW) error="Query interrupted, busy, or invalid";
done:
    if(stmt) sqlite3_finalize(stmt);
    sqlite3_progress_handler(db->handle,0,NULL,NULL);
    sqlite3_set_authorizer(db->handle,NULL,NULL);
    if(error) janet_panic(error);
    JanetTable *result=janet_table(2);
    janet_table_put(result,janet_ckeywordv("columns"),janet_wrap_array(columns));
    janet_table_put(result,janet_ckeywordv("rows"),janet_wrap_array(rows));
    return janet_wrap_table(result);
}
/* One statement per call makes post-eval commit/rollback notification precise. */
static Janet eval_one(int32_t argc, Janet *argv) {
    janet_arity(argc,2,3);
    Db *db=janet_getabstract(argv,0,&sql_conn_type);
    if(db->flags & FLAG_CLOSED) janet_panic(MSG_DB_CLOSED);
    const uint8_t *query=janet_getstring(argv,1);
    int length=janet_string_length(query);
    if(has_null(query,length)) janet_panic("Embedded NUL in SQL");
    sqlite3_stmt *stmt=NULL; const char *tail=NULL;
    int rc=sqlite3_prepare_v2(db->handle,(const char*)query,length,&stmt,&tail);
    int valid=stmt!=NULL;
    if(stmt) sqlite3_finalize(stmt);
    if(rc!=SQLITE_OK) janet_panic("Invalid statement");
    while(tail && (*tail==' ' || *tail=='\n' || *tail=='\r' || *tail=='\t')) ++tail;
    if(!valid || (tail && *tail)) janet_panic("Use one statement per tracked eval call");
    return sql_eval(argc,argv);
}
JANET_EXPORT JanetBuildConfig _janet_mod_config(void) {return janet_config_current();}
JANET_EXPORT void _janet_init(JanetTable *env) {
    upstream_sqlite_init(env);
    static const JanetReg extra[]={
      {"readonly-open",readonly_open,"Open existing database read-only."},
      {"safe-query",safe_query,"Run one read query, with CPU, row and byte budgets."},
      {"eval-one",eval_one,"Internal: evaluate one statement with the upstream binding."},
      {NULL,NULL,NULL}};
    janet_cfuns(env,"sqlite3",extra);
}
