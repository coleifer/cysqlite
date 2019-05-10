from cpython.object cimport PyObject


cdef struct sqlite3_index_constraint:
    int iColumn
    unsigned char op
    unsigned char usable
    int iTermOffset


cdef struct sqlite3_index_orderby:
    int iColumn
    unsigned char desc


cdef struct sqlite3_index_constraint_usage:
    int argvIndex
    unsigned char omit


cdef extern from "sqlite3.h" nogil:
    ctypedef struct sqlite3:
        int busyTimeout
    ctypedef struct sqlite3_backup
    ctypedef struct sqlite3_blob
    ctypedef struct sqlite3_context
    ctypedef struct sqlite3_value
    ctypedef long long sqlite3_int64
    ctypedef unsigned long long sqlite_uint64

    # Virtual tables.
    ctypedef struct sqlite3_module  # Forward reference.
    ctypedef struct sqlite3_vtab:
        const sqlite3_module *pModule
        int nRef
        char *zErrMsg
    ctypedef struct sqlite3_vtab_cursor:
        sqlite3_vtab *pVtab

    ctypedef struct sqlite3_index_info:
        int nConstraint
        sqlite3_index_constraint *aConstraint
        int nOrderBy
        sqlite3_index_orderby *aOrderBy
        sqlite3_index_constraint_usage *aConstraintUsage
        int idxNum
        char *idxStr
        int needToFreeIdxStr
        int orderByConsumed
        double estimatedCost
        sqlite3_int64 estimatedRows
        int idxFlags

    ctypedef struct sqlite3_module:
        int iVersion
        int (*xCreate)(sqlite3*, void *pAux, int argc, char **argv,
                       sqlite3_vtab **ppVTab, char**)
        int (*xConnect)(sqlite3*, void *pAux, int argc, char **argv,
                        sqlite3_vtab **ppVTab, char**)
        int (*xBestIndex)(sqlite3_vtab *pVTab, sqlite3_index_info*)
        int (*xDisconnect)(sqlite3_vtab *pVTab)
        int (*xDestroy)(sqlite3_vtab *pVTab)
        int (*xOpen)(sqlite3_vtab *pVTab, sqlite3_vtab_cursor **ppCursor)
        int (*xClose)(sqlite3_vtab_cursor*)
        int (*xFilter)(sqlite3_vtab_cursor*, int idxNum, const char *idxStr,
                       int argc, sqlite3_value **argv)
        int (*xNext)(sqlite3_vtab_cursor*)
        int (*xEof)(sqlite3_vtab_cursor*)
        int (*xColumn)(sqlite3_vtab_cursor*, sqlite3_context *, int)
        int (*xRowid)(sqlite3_vtab_cursor*, sqlite3_int64 *pRowid)
        int (*xUpdate)(sqlite3_vtab *pVTab, int, sqlite3_value **,
                       sqlite3_int64 **)
        int (*xBegin)(sqlite3_vtab *pVTab)
        int (*xSync)(sqlite3_vtab *pVTab)
        int (*xCommit)(sqlite3_vtab *pVTab)
        int (*xRollback)(sqlite3_vtab *pVTab)
        int (*xFindFunction)(sqlite3_vtab *pVTab, int nArg, const char *zName,
                             void (**pxFunc)(sqlite3_context *, int,
                                             sqlite3_value **),
                             void **ppArg)
        int (*xRename)(sqlite3_vtab *pVTab, const char *zNew)
        int (*xSavepoint)(sqlite3_vtab *pVTab, int)
        int (*xRelease)(sqlite3_vtab *pVTab, int)
        int (*xRollbackTo)(sqlite3_vtab *pVTab, int)

    cdef int sqlite3_declare_vtab(sqlite3 *db, const char *zSQL)
    cdef int sqlite3_create_module(sqlite3 *db, const char *zName,
                                   const sqlite3_module *p, void *pClientData)

    cdef const char sqlite3_version[]
    cdef int SQLITE_VERSION_NUMBER

    # Encoding.
    cdef int SQLITE_UTF8

    # Return values.
    cdef int SQLITE_OK
    cdef int SQLITE_ERROR
    cdef int SQLITE_INTERNAL
    cdef int SQLITE_PERM
    cdef int SQLITE_ABORT
    cdef int SQLITE_BUSY
    cdef int SQLITE_LOCKED
    cdef int SQLITE_NOMEM
    cdef int SQLITE_READONLY
    cdef int SQLITE_INTERRUPT
    cdef int SQLITE_DONE

    # Function type.
    cdef int SQLITE_DETERMINISTIC

    # Types of filtering operations.
    cdef int SQLITE_INDEX_CONSTRAINT_EQ
    cdef int SQLITE_INDEX_CONSTRAINT_GT
    cdef int SQLITE_INDEX_CONSTRAINT_LE
    cdef int SQLITE_INDEX_CONSTRAINT_LT
    cdef int SQLITE_INDEX_CONSTRAINT_GE
    cdef int SQLITE_INDEX_CONSTRAINT_MATCH

    # sqlite_value_type.
    cdef int SQLITE_INTEGER
    cdef int SQLITE_FLOAT
    cdef int SQLITE3_TEXT
    cdef int SQLITE_TEXT
    cdef int SQLITE_BLOB
    cdef int SQLITE_NULL

    ctypedef void (*sqlite3_destructor_type)(void*)

    # Converting from Sqlite -> Python.
    cdef const void *sqlite3_value_blob(sqlite3_value*)
    cdef int sqlite3_value_bytes(sqlite3_value*)
    cdef double sqlite3_value_double(sqlite3_value*)
    cdef int sqlite3_value_int(sqlite3_value*)
    cdef sqlite3_int64 sqlite3_value_int64(sqlite3_value*)
    cdef const unsigned char *sqlite3_value_text(sqlite3_value*)
    cdef int sqlite3_value_type(sqlite3_value*)
    cdef int sqlite3_value_numeric_type(sqlite3_value*)

    # Converting from Python -> Sqlite.
    cdef void sqlite3_result_blob(sqlite3_context*, const void *, int,
                                  void(*)(void*))
    cdef void sqlite3_result_double(sqlite3_context*, double)
    cdef void sqlite3_result_error(sqlite3_context*, const char*, int)
    cdef void sqlite3_result_error_toobig(sqlite3_context*)
    cdef void sqlite3_result_error_nomem(sqlite3_context*)
    cdef void sqlite3_result_error_code(sqlite3_context*, int)
    cdef void sqlite3_result_int(sqlite3_context*, int)
    cdef void sqlite3_result_int64(sqlite3_context*, sqlite3_int64)
    cdef void sqlite3_result_null(sqlite3_context*)
    cdef void sqlite3_result_text(sqlite3_context*, const char*, int,
                                  void(*)(void*))
    cdef void sqlite3_result_value(sqlite3_context*, sqlite3_value*)

    cdef void *sqlite3_aggregate_context(sqlite3_context*, int nBytes)
    cdef void *sqlite3_user_data(sqlite3_context*)

    # Memory management.
    cdef void* sqlite3_malloc(int)
    cdef void sqlite3_free(void *)

    cdef int sqlite3_changes(sqlite3 *db)
    cdef int sqlite3_get_autocommit(sqlite3 *db)
    cdef sqlite3_int64 sqlite3_last_insert_rowid(sqlite3 *db)

    cdef void *sqlite3_commit_hook(sqlite3 *, int(*)(void *), void *)
    cdef void *sqlite3_rollback_hook(sqlite3 *, void(*)(void *), void *)
    cdef void *sqlite3_update_hook(
        sqlite3 *,
        void(*)(void *, int, char *, char *, sqlite3_int64),
        void *)

    cdef int SQLITE_STATUS_MEMORY_USED = 0
    cdef int SQLITE_STATUS_PAGECACHE_USED = 1
    cdef int SQLITE_STATUS_PAGECACHE_OVERFLOW = 2
    cdef int SQLITE_STATUS_SCRATCH_USED = 3
    cdef int SQLITE_STATUS_SCRATCH_OVERFLOW = 4
    cdef int SQLITE_STATUS_MALLOC_SIZE = 5
    cdef int SQLITE_STATUS_PARSER_STACK = 6
    cdef int SQLITE_STATUS_PAGECACHE_SIZE = 7
    cdef int SQLITE_STATUS_SCRATCH_SIZE = 8
    cdef int SQLITE_STATUS_MALLOC_COUNT = 9
    cdef int sqlite3_status(int op, int *pCurrent, int *pHighwater, int resetFlag)

    cdef int SQLITE_DBSTATUS_LOOKASIDE_USED = 0
    cdef int SQLITE_DBSTATUS_CACHE_USED = 1
    cdef int SQLITE_DBSTATUS_SCHEMA_USED = 2
    cdef int SQLITE_DBSTATUS_STMT_USED = 3
    cdef int SQLITE_DBSTATUS_LOOKASIDE_HIT = 4
    cdef int SQLITE_DBSTATUS_LOOKASIDE_MISS_SIZE = 5
    cdef int SQLITE_DBSTATUS_LOOKASIDE_MISS_FULL = 6
    cdef int SQLITE_DBSTATUS_CACHE_HIT = 7
    cdef int SQLITE_DBSTATUS_CACHE_MISS = 8
    cdef int SQLITE_DBSTATUS_CACHE_WRITE = 9
    cdef int SQLITE_DBSTATUS_DEFERRED_FKS = 10
    #cdef int SQLITE_DBSTATUS_CACHE_USED_SHARED = 11
    cdef int sqlite3_db_status(sqlite3 *, int op, int *pCur, int *pHigh, int reset)

    cdef int SQLITE_DELETE = 9
    cdef int SQLITE_INSERT = 18
    cdef int SQLITE_UPDATE = 23

    cdef int SQLITE_CONFIG_SINGLETHREAD = 1  # None
    cdef int SQLITE_CONFIG_MULTITHREAD = 2  # None
    cdef int SQLITE_CONFIG_SERIALIZED = 3  # None
    cdef int SQLITE_CONFIG_SCRATCH = 6  # void *, int sz, int N
    cdef int SQLITE_CONFIG_PAGECACHE = 7  # void *, int sz, int N
    cdef int SQLITE_CONFIG_HEAP = 8  # void *, int nByte, int min
    cdef int SQLITE_CONFIG_MEMSTATUS = 9  # boolean
    cdef int SQLITE_CONFIG_LOOKASIDE = 13  # int, int
    cdef int SQLITE_CONFIG_URI = 17  # int
    cdef int SQLITE_CONFIG_MMAP_SIZE = 22  # sqlite3_int64, sqlite3_int64
    cdef int SQLITE_CONFIG_STMTJRNL_SPILL = 26  # int nByte
    cdef int SQLITE_DBCONFIG_MAINDBNAME = 1000  # const char*
    cdef int SQLITE_DBCONFIG_LOOKASIDE = 1001  # void* int int
    cdef int SQLITE_DBCONFIG_ENABLE_FKEY = 1002  # int int*
    cdef int SQLITE_DBCONFIG_ENABLE_TRIGGER = 1003  # int int*
    cdef int SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER = 1004  # int int*
    cdef int SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION = 1005  # int int*
    cdef int SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE = 1006  # int int*
    cdef int SQLITE_DBCONFIG_ENABLE_QPSG = 1007  # int int*

    cdef int sqlite3_config(int, ...)
    cdef int sqlite3_db_config(sqlite3*, int op, ...)

    # Misc.
    cdef int sqlite3_busy_handler(sqlite3 *db, int(*)(void *, int), void *)
    cdef int sqlite3_sleep(int ms)
    cdef sqlite3_backup *sqlite3_backup_init(
        sqlite3 *pDest,
        const char *zDestName,
        sqlite3 *pSource,
        const char *zSourceName)

    # Backup.
    cdef int sqlite3_backup_step(sqlite3_backup *p, int nPage)
    cdef int sqlite3_backup_finish(sqlite3_backup *p)
    cdef int sqlite3_backup_remaining(sqlite3_backup *p)
    cdef int sqlite3_backup_pagecount(sqlite3_backup *p)

    # Error handling.
    cdef int sqlite3_errcode(sqlite3 *db)
    cdef int sqlite3_errstr(int)
    cdef const char *sqlite3_errmsg(sqlite3 *db)

    cdef int sqlite3_blob_open(
          sqlite3*,
          const char *zDb,
          const char *zTable,
          const char *zColumn,
          sqlite3_int64 iRow,
          int flags,
          sqlite3_blob **ppBlob)
    cdef int sqlite3_blob_reopen(sqlite3_blob *, sqlite3_int64)
    cdef int sqlite3_blob_close(sqlite3_blob *)
    cdef int sqlite3_blob_bytes(sqlite3_blob *)
    cdef int sqlite3_blob_read(sqlite3_blob *, void *Z, int N, int iOffset)
    cdef int sqlite3_blob_write(sqlite3_blob *, const void *z, int n,
                                int iOffset)

    # User-defined window functions.
    cdef int sqlite3_create_window_function(
        sqlite3 *db, const char *zFunctionName, int nArg, int eTextRep, void *,
        void (*xStep)(sqlite3_context *, int, sqlite3_value **),
        void (*xFinal)(sqlite3_context *),
        void (*xValue)(sqlite3_context *),
        void (*xInverse)(sqlite3_context *, int, sqlite3_value **),
        void (*xDestroy)(void *))


cdef extern from "_pysqlite/connection.h":
    ctypedef struct pysqlite_Connection:
        sqlite3* db
        double timeout
        int initialized
        PyObject* isolation_level
        char* begin_statement
