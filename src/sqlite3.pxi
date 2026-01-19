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
    ctypedef struct sqlite3_mutex
    ctypedef struct sqlite3_stmt
    ctypedef struct sqlite3_str
    ctypedef struct sqlite3_value
    ctypedef struct sqlite3_vfs
    ctypedef long long sqlite3_int64
    ctypedef unsigned long long sqlite3_uint64

    cdef char[] SQLITE_VERSION
    cdef int SQLITE_VERSION_NUMBER

    cdef int SQLITE_OK  # Successful result
    cdef int SQLITE_ERROR  # Generic error
    cdef int SQLITE_INTERNAL  # Internal logic error in SQLite
    cdef int SQLITE_PERM  # Access permission denied
    cdef int SQLITE_ABORT  # Callback routine requested an abort
    cdef int SQLITE_BUSY  # The database file is locked
    cdef int SQLITE_LOCKED  # A table in the database is locked
    cdef int SQLITE_NOMEM  # A malloc() failed
    cdef int SQLITE_READONLY  # Attempt to write a readonly database
    cdef int SQLITE_INTERRUPT  # Operation terminated by sqlite3_interrupt()
    cdef int SQLITE_IOERR   # Some kind of disk I/O error occurred
    cdef int SQLITE_CORRUPT   # The database disk image is malformed
    cdef int SQLITE_NOTFOUND   # Unknown opcode in sqlite3_file_control()
    cdef int SQLITE_FULL   # Insertion failed because database is full
    cdef int SQLITE_CANTOPEN   # Unable to open the database file
    cdef int SQLITE_PROTOCOL   # Database lock protocol error
    cdef int SQLITE_EMPTY   # Internal use only
    cdef int SQLITE_SCHEMA   # The database schema changed
    cdef int SQLITE_TOOBIG   # String or BLOB exceeds size limit
    cdef int SQLITE_CONSTRAINT   # Abort due to constraint violation
    cdef int SQLITE_MISMATCH   # Data type mismatch
    cdef int SQLITE_MISUSE   # Library used incorrectly
    cdef int SQLITE_NOLFS   # Uses OS features not supported on host
    cdef int SQLITE_AUTH   # Authorization denied
    cdef int SQLITE_FORMAT   # Not used
    cdef int SQLITE_RANGE   # 2nd parameter to sqlite3_bind out of range
    cdef int SQLITE_NOTADB   # File opened that is not a database file
    cdef int SQLITE_NOTICE   # Notifications from sqlite3_log()
    cdef int SQLITE_WARNING   # Warnings from sqlite3_log()
    cdef int SQLITE_ROW  # sqlite3_step() has another row ready
    cdef int SQLITE_DONE  # sqlite3_step() has finished executing

    cdef int SQLITE_OPEN_READONLY  # Ok for sqlite3_open_v2()
    cdef int SQLITE_OPEN_READWRITE  # Ok for sqlite3_open_v2()
    cdef int SQLITE_OPEN_CREATE  # Ok for sqlite3_open_v2()
    cdef int SQLITE_OPEN_DELETEONCLOSE  # VFS only
    cdef int SQLITE_OPEN_EXCLUSIVE  # VFS only
    cdef int SQLITE_OPEN_AUTOPROXY  # VFS only
    cdef int SQLITE_OPEN_URI  # Ok for sqlite3_open_v2()
    cdef int SQLITE_OPEN_MEMORY  # Ok for sqlite3_open_v2()
    cdef int SQLITE_OPEN_MAIN_DB  # VFS only
    cdef int SQLITE_OPEN_TEMP_DB  # VFS only
    cdef int SQLITE_OPEN_TRANSIENT_DB  # VFS only
    cdef int SQLITE_OPEN_MAIN_JOURNAL  # VFS only
    cdef int SQLITE_OPEN_TEMP_JOURNAL  # VFS only
    cdef int SQLITE_OPEN_SUBJOURNAL  # VFS only
    cdef int SQLITE_OPEN_MASTER_JOURNAL  # VFS only
    cdef int SQLITE_OPEN_NOMUTEX  # Ok for sqlite3_open_v2()
    cdef int SQLITE_OPEN_FULLMUTEX  # Ok for sqlite3_open_v2()
    cdef int SQLITE_OPEN_SHAREDCACHE  # Ok for sqlite3_open_v2()
    cdef int SQLITE_OPEN_PRIVATECACHE  # Ok for sqlite3_open_v2()
    cdef int SQLITE_OPEN_WAL  # VFS only

    cdef int SQLITE_LOCK_NONE
    cdef int SQLITE_LOCK_SHARED
    cdef int SQLITE_LOCK_RESERVED
    cdef int SQLITE_LOCK_PENDING
    cdef int SQLITE_LOCK_EXCLUSIVE
    cdef int SQLITE_SYNC_NORMAL
    cdef int SQLITE_SYNC_FULL
    cdef int SQLITE_SYNC_DATAONLY

    cdef int SQLITE_CONFIG_SINGLETHREAD  # nil
    cdef int SQLITE_CONFIG_MULTITHREAD  # nil
    cdef int SQLITE_CONFIG_SERIALIZED  # nil
    cdef int SQLITE_CONFIG_MALLOC  # sqlite3_mem_methods*
    cdef int SQLITE_CONFIG_GETMALLOC  # sqlite3_mem_methods*
    cdef int SQLITE_CONFIG_SCRATCH  # No longer used
    cdef int SQLITE_CONFIG_PAGECACHE  # void*, int sz, int N
    cdef int SQLITE_CONFIG_HEAP  # void*, int nByte, int min
    cdef int SQLITE_CONFIG_MEMSTATUS  # boolean
    cdef int SQLITE_CONFIG_MUTEX   # sqlite3_mutex_methods*
    cdef int SQLITE_CONFIG_GETMUTEX   # sqlite3_mutex_methods*
    cdef int SQLITE_CONFIG_LOOKASIDE   # int int
    cdef int SQLITE_CONFIG_PCACHE   # no-op
    cdef int SQLITE_CONFIG_GETPCACHE   # no-op
    cdef int SQLITE_CONFIG_LOG   # xFunc, void*
    cdef int SQLITE_CONFIG_URI   # int
    cdef int SQLITE_CONFIG_PCACHE2   # sqlite3_pcache_methods2*
    cdef int SQLITE_CONFIG_GETPCACHE2   # sqlite3_pcache_methods2*
    cdef int SQLITE_CONFIG_COVERING_INDEX_SCAN   # int
    cdef int SQLITE_CONFIG_SQLLOG   # xSqllog, void*
    cdef int SQLITE_CONFIG_MMAP_SIZE   # sqlite3_int64, sqlite3_int64
    cdef int SQLITE_CONFIG_WIN32_HEAPSIZE   # int nByte
    cdef int SQLITE_CONFIG_PCACHE_HDRSZ   # int *psz
    cdef int SQLITE_CONFIG_PMASZ   # unsigned int szPma
    cdef int SQLITE_CONFIG_STMTJRNL_SPILL   # int nByte
    cdef int SQLITE_CONFIG_SMALL_MALLOC   # boolean
    cdef int SQLITE_CONFIG_SORTERREF_SIZE   # int nByte
    cdef int SQLITE_CONFIG_MEMDB_MAXSIZE   # sqlite3_int64

    cdef int SQLITE_DBCONFIG_MAINDBNAME  # const char*
    cdef int SQLITE_DBCONFIG_LOOKASIDE  # void* int int
    cdef int SQLITE_DBCONFIG_ENABLE_FKEY  # int int*
    cdef int SQLITE_DBCONFIG_ENABLE_TRIGGER  # int int*
    cdef int SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER  # int int*
    cdef int SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION  # int int*
    cdef int SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE  # int int*
    cdef int SQLITE_DBCONFIG_ENABLE_QPSG  # int int*
    cdef int SQLITE_DBCONFIG_TRIGGER_EQP  # int int*
    cdef int SQLITE_DBCONFIG_RESET_DATABASE  # int int*
    cdef int SQLITE_DBCONFIG_DEFENSIVE  # int int*
    cdef int SQLITE_DBCONFIG_WRITABLE_SCHEMA  # int int*
    cdef int SQLITE_DBCONFIG_MAX  # Largest DBCONFIG

    cdef int SQLITE_DENY  # Abort the SQL statement with an error
    cdef int SQLITE_IGNORE  # Don't allow access, but don't generate an error

    cdef int SQLITE_CREATE_INDEX  # Index Name      Table Name
    cdef int SQLITE_CREATE_TABLE  # Table Name      NULL
    cdef int SQLITE_CREATE_TEMP_INDEX  # Index Name      Table Name
    cdef int SQLITE_CREATE_TEMP_TABLE  # Table Name      NULL
    cdef int SQLITE_CREATE_TEMP_TRIGGER  # Trigger Name    Table Name
    cdef int SQLITE_CREATE_TEMP_VIEW  # View Name       NULL
    cdef int SQLITE_CREATE_TRIGGER  # Trigger Name    Table Name
    cdef int SQLITE_CREATE_VIEW  # View Name       NULL
    cdef int SQLITE_DELETE  # Table Name      NULL
    cdef int SQLITE_DROP_INDEX  # Index Name      Table Name
    cdef int SQLITE_DROP_TABLE  # Table Name      NULL
    cdef int SQLITE_DROP_TEMP_INDEX  # Index Name      Table Name
    cdef int SQLITE_DROP_TEMP_TABLE  # Table Name      NULL
    cdef int SQLITE_DROP_TEMP_TRIGGER  # Trigger Name    Table Name
    cdef int SQLITE_DROP_TEMP_VIEW  # View Name       NULL
    cdef int SQLITE_DROP_TRIGGER  # Trigger Name    Table Name
    cdef int SQLITE_DROP_VIEW  # View Name       NULL
    cdef int SQLITE_INSERT  # Table Name      NULL
    cdef int SQLITE_PRAGMA  # Pragma Name     1st arg or NULL
    cdef int SQLITE_READ  # Table Name      Column Name
    cdef int SQLITE_SELECT  # NULL            NULL
    cdef int SQLITE_TRANSACTION  # Operation       NULL
    cdef int SQLITE_UPDATE  # Table Name      Column Name
    cdef int SQLITE_ATTACH  # Filename        NULL
    cdef int SQLITE_DETACH  # Database Name   NULL
    cdef int SQLITE_ALTER_TABLE  # Database Name   Table Name
    cdef int SQLITE_REINDEX  # Index Name      NULL
    cdef int SQLITE_ANALYZE  # Table Name      NULL
    cdef int SQLITE_CREATE_VTABLE  # Table Name      Module Name
    cdef int SQLITE_DROP_VTABLE  # Table Name      Module Name
    cdef int SQLITE_FUNCTION  # NULL            Function Name
    cdef int SQLITE_SAVEPOINT  # Operation       Savepoint Name
    cdef int SQLITE_COPY  # No longer used
    cdef int SQLITE_RECURSIVE  # NULL            NULL

    cdef int SQLITE_TRACE_STMT
    cdef int SQLITE_TRACE_PROFILE
    cdef int SQLITE_TRACE_ROW
    cdef int SQLITE_TRACE_CLOSE

    cdef int SQLITE_LIMIT_LENGTH
    cdef int SQLITE_LIMIT_SQL_LENGTH
    cdef int SQLITE_LIMIT_COLUMN
    cdef int SQLITE_LIMIT_EXPR_DEPTH
    cdef int SQLITE_LIMIT_COMPOUND_SELECT
    cdef int SQLITE_LIMIT_VDBE_OP
    cdef int SQLITE_LIMIT_FUNCTION_ARG
    cdef int SQLITE_LIMIT_ATTACHED
    cdef int SQLITE_LIMIT_LIKE_PATTERN_LENGTH
    cdef int SQLITE_LIMIT_VARIABLE_NUMBER
    cdef int SQLITE_LIMIT_TRIGGER_DEPTH
    cdef int SQLITE_LIMIT_WORKER_THREADS

    cdef int SQLITE_PREPARE_PERSISTENT
    cdef int SQLITE_PREPARE_NORMALIZE
    cdef int SQLITE_PREPARE_NO_VTAB

    cdef int SQLITE_INTEGER
    cdef int SQLITE_FLOAT
    cdef int SQLITE_TEXT
    cdef int SQLITE_BLOB
    cdef int SQLITE_NULL

    cdef int SQLITE_UTF8
    cdef int SQLITE_UTF16LE
    cdef int SQLITE_UTF16BE
    cdef int SQLITE_UTF16
    cdef int SQLITE_ANY
    cdef int SQLITE_UTF16_ALIGNED
    cdef int SQLITE_DETERMINISTIC

    ctypedef void (*sqlite3_destructor_type)(void*)
    cdef sqlite3_destructor_type SQLITE_TRANSIENT

    cdef int SQLITE_INDEX_SCAN_UNIQUE  # Scan visits at most 1 row
    cdef int SQLITE_INDEX_CONSTRAINT_EQ
    cdef int SQLITE_INDEX_CONSTRAINT_GT
    cdef int SQLITE_INDEX_CONSTRAINT_LE
    cdef int SQLITE_INDEX_CONSTRAINT_LT
    cdef int SQLITE_INDEX_CONSTRAINT_GE
    cdef int SQLITE_INDEX_CONSTRAINT_MATCH
    cdef int SQLITE_INDEX_CONSTRAINT_LIKE
    cdef int SQLITE_INDEX_CONSTRAINT_GLOB
    cdef int SQLITE_INDEX_CONSTRAINT_REGEXP
    cdef int SQLITE_INDEX_CONSTRAINT_NE
    cdef int SQLITE_INDEX_CONSTRAINT_ISNOT
    cdef int SQLITE_INDEX_CONSTRAINT_ISNOTNULL
    cdef int SQLITE_INDEX_CONSTRAINT_ISNULL
    cdef int SQLITE_INDEX_CONSTRAINT_IS
    cdef int SQLITE_INDEX_CONSTRAINT_FUNCTION

    cdef int SQLITE_STATUS_MEMORY_USED
    cdef int SQLITE_STATUS_PAGECACHE_USED
    cdef int SQLITE_STATUS_PAGECACHE_OVERFLOW
    cdef int SQLITE_STATUS_SCRATCH_USED  # NOT USED
    cdef int SQLITE_STATUS_SCRATCH_OVERFLOW  # NOT USED
    cdef int SQLITE_STATUS_MALLOC_SIZE
    cdef int SQLITE_STATUS_PARSER_STACK
    cdef int SQLITE_STATUS_PAGECACHE_SIZE
    cdef int SQLITE_STATUS_SCRATCH_SIZE  # NOT USED
    cdef int SQLITE_STATUS_MALLOC_COUNT

    cdef int SQLITE_DBSTATUS_LOOKASIDE_USED
    cdef int SQLITE_DBSTATUS_CACHE_USED
    cdef int SQLITE_DBSTATUS_SCHEMA_USED
    cdef int SQLITE_DBSTATUS_STMT_USED
    cdef int SQLITE_DBSTATUS_LOOKASIDE_HIT
    cdef int SQLITE_DBSTATUS_LOOKASIDE_MISS_SIZE
    cdef int SQLITE_DBSTATUS_LOOKASIDE_MISS_FULL
    cdef int SQLITE_DBSTATUS_CACHE_HIT
    cdef int SQLITE_DBSTATUS_CACHE_MISS
    cdef int SQLITE_DBSTATUS_CACHE_WRITE
    cdef int SQLITE_DBSTATUS_DEFERRED_FKS
    cdef int SQLITE_DBSTATUS_CACHE_USED_SHARED
    cdef int SQLITE_DBSTATUS_CACHE_SPILL
    cdef int SQLITE_DBSTATUS_MAX  # Largest defined DBSTATUS

    cdef int SQLITE_STMTSTATUS_FULLSCAN_STEP
    cdef int SQLITE_STMTSTATUS_SORT
    cdef int SQLITE_STMTSTATUS_AUTOINDEX
    cdef int SQLITE_STMTSTATUS_VM_STEP
    cdef int SQLITE_STMTSTATUS_REPREPARE
    cdef int SQLITE_STMTSTATUS_RUN
    cdef int SQLITE_STMTSTATUS_MEMUSED

    cdef int SQLITE_CHECKPOINT_PASSIVE  # Do as much as possible w/o blocking
    cdef int SQLITE_CHECKPOINT_FULL  # Wait for writers, then checkpoint
    cdef int SQLITE_CHECKPOINT_RESTART  # Like FULL but wait for for readers
    cdef int SQLITE_CHECKPOINT_TRUNCATE  # Like RESTART but also truncate WAL

    cdef int SQLITE_VTAB_CONSTRAINT_SUPPORT
    cdef int SQLITE_ROLLBACK
    cdef int SQLITE_FAIL
    cdef int SQLITE_REPLACE

    cdef int SQLITE_SCANSTAT_NLOOP
    cdef int SQLITE_SCANSTAT_NVISIT
    cdef int SQLITE_SCANSTAT_EST
    cdef int SQLITE_SCANSTAT_NAME
    cdef int SQLITE_SCANSTAT_EXPLAIN
    cdef int SQLITE_SCANSTAT_SELECTID
    cdef int SQLITE_SERIALIZE_NOCOPY  # Do no memory allocations
    cdef int SQLITE_DESERIALIZE_FREEONCLOSE  # Call sqlite3_free() on close
    cdef int SQLITE_DESERIALIZE_RESIZEABLE  # Resize using sqlite3_realloc64()
    cdef int SQLITE_DESERIALIZE_READONLY  # Database is read-only

    ctypedef struct sqlite3_vfs:
        sqlite3_vfs *pNext
        const char *zName

    cdef sqlite3_vfs *sqlite3_vfs_find(const char *zVfsName)

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

    # API functions.
    cdef const char sqlite3_version[]
    cdef const char *sqlite3_libversion()
    cdef const char *sqlite3_sourceid()
    cdef int sqlite3_libversion_number()
    cdef int sqlite3_compileoption_used(const char *zOptName)
    #cdef const char *sqlite3_compileoption_get(int N)
    cdef int sqlite3_threadsafe()
    #cdef int sqlite3_close(sqlite3*)
    cdef int sqlite3_close_v2(sqlite3*)
    cdef int sqlite3_exec(sqlite3*, const char *sql,
            int (*callback)(void*,int,char**,char**),
            void *,
            char **errmsg)
    #cdef int sqlite3_initialize()
    #cdef int sqlite3_shutdown()
    #cdef int sqlite3_os_init()
    #cdef int sqlite3_os_end()
    cdef int sqlite3_config(int, ...)
    cdef int sqlite3_db_config(sqlite3*, int op, ...)
    cdef int sqlite3_extended_result_codes(sqlite3*, int onoff)
    cdef sqlite3_int64 sqlite3_last_insert_rowid(sqlite3*)
    cdef void sqlite3_set_last_insert_rowid(sqlite3*, sqlite3_int64)
    cdef int sqlite3_changes(sqlite3*)
    cdef int sqlite3_total_changes(sqlite3*)
    cdef void sqlite3_interrupt(sqlite3*)
    cdef int sqlite3_complete(const char *sql)
    #cdef int sqlite3_complete16(const void *sql)
    cdef int sqlite3_busy_handler(sqlite3*,int(*)(void*,int),void*)
    cdef int sqlite3_busy_timeout(sqlite3*, int ms)
    #cdef int sqlite3_get_table(sqlite3 *db, const char *zSql, char ***pazResult, int *pnRow, int *pnColumn, char **pzErrmsg)
    #cdef void sqlite3_free_table(char **result)
    #cdef char *sqlite3_mprintf(const char*,...)
    #cdef char *sqlite3_vmprintf(const char*, va_list)
    #cdef char *sqlite3_snprintf(int,char*,const char*, ...)
    #cdef char *sqlite3_vsnprintf(int,char*,const char*, va_list)
    cdef void *sqlite3_malloc(int)
    cdef void *sqlite3_malloc64(sqlite3_uint64)
    cdef void *sqlite3_realloc(void*, int)
    cdef void *sqlite3_realloc64(void*, sqlite3_uint64)
    cdef void sqlite3_free(void*)
    cdef sqlite3_uint64 sqlite3_msize(void*)
    cdef sqlite3_int64 sqlite3_memory_used()
    cdef sqlite3_int64 sqlite3_memory_highwater(int resetFlag)
    #cdef void sqlite3_randomness(int N, void *P)
    cdef int sqlite3_set_authorizer(
        sqlite3*,
        int (*xAuth)(
            void*,
            int,
            const char*,
            const char*,
            const char*,
            const char*),
        void *pUserData)
    cdef int sqlite3_trace_v2(
        sqlite3*,
        unsigned uMask,
        int(*xCallback)(unsigned,void*,void*,void*),
        void *pCtx)
    cdef void sqlite3_progress_handler(
        sqlite3*,
        int,
        int(*)(void*),
        void*)
    #cdef int sqlite3_open(const char *filename, sqlite3 **ppDb)
    #cdef int sqlite3_open16(const void *filename, sqlite3 **ppDb)
    cdef int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs)
    cdef const char *sqlite3_uri_parameter(const char *zFilename, const char *zParam)
    cdef int sqlite3_uri_boolean(const char *zFile, const char *zParam, int bDefault)
    cdef sqlite3_int64 sqlite3_uri_int64(const char*, const char*, sqlite3_int64)
    cdef int sqlite3_errcode(sqlite3 *db)
    cdef int sqlite3_extended_errcode(sqlite3 *db)
    cdef const char *sqlite3_errmsg(sqlite3*)
    #cdef const void *sqlite3_errmsg16(sqlite3*)
    cdef const char *sqlite3_errstr(int)
    cdef int sqlite3_limit(sqlite3*, int id, int newVal)
    #cdef int sqlite3_prepare(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail)
    cdef int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail)
    cdef int sqlite3_prepare_v3(sqlite3 *db, const char *zSql, int nByte, unsigned int prepFlags, sqlite3_stmt **ppStmt, const char **pzTail)
    #cdef int sqlite3_prepare16(sqlite3 *db, const void *zSql, int nByte, sqlite3_stmt **ppStmt, const void **pzTail)
    #cdef int sqlite3_prepare16_v2(sqlite3 *db, const void *zSql, int nByte, sqlite3_stmt **ppStmt, const void **pzTail)
    #cdef int sqlite3_prepare16_v3(sqlite3 *db, const void *zSql, int nByte, unsigned int prepFlags, sqlite3_stmt **ppStmt, const void **pzTail)
    cdef const char *sqlite3_sql(sqlite3_stmt *pStmt)
    cdef char *sqlite3_expanded_sql(sqlite3_stmt *pStmt)
    cdef const char *sqlite3_normalized_sql(sqlite3_stmt *pStmt)
    cdef int sqlite3_stmt_readonly(sqlite3_stmt *pStmt)
    cdef int sqlite3_stmt_isexplain(sqlite3_stmt *pStmt)
    cdef int sqlite3_stmt_busy(sqlite3_stmt*)
    cdef int sqlite3_bind_blob(sqlite3_stmt*, int, const void*, int n, void(*)(void*))
    cdef int sqlite3_bind_blob64(sqlite3_stmt*, int, const void*, sqlite3_uint64, void(*)(void*))
    cdef int sqlite3_bind_double(sqlite3_stmt*, int, double)
    cdef int sqlite3_bind_int(sqlite3_stmt*, int, int)
    cdef int sqlite3_bind_int64(sqlite3_stmt*, int, sqlite3_int64)
    cdef int sqlite3_bind_null(sqlite3_stmt*, int)
    cdef int sqlite3_bind_text(sqlite3_stmt*,int,const char*,int,void(*)(void*))
    #cdef int sqlite3_bind_text16(sqlite3_stmt*, int, const void*, int, void(*)(void*))
    cdef int sqlite3_bind_text64(sqlite3_stmt*, int, const char*, sqlite3_uint64, void(*)(void*), unsigned char encoding)
    cdef int sqlite3_bind_value(sqlite3_stmt*, int, const sqlite3_value*)
    cdef int sqlite3_bind_pointer(sqlite3_stmt*, int, void*, const char*,void(*)(void*))
    cdef int sqlite3_bind_zeroblob(sqlite3_stmt*, int, int n)
    cdef int sqlite3_bind_zeroblob64(sqlite3_stmt*, int, sqlite3_uint64)
    cdef int sqlite3_bind_parameter_count(sqlite3_stmt*)
    cdef const char *sqlite3_bind_parameter_name(sqlite3_stmt*, int)
    cdef int sqlite3_bind_parameter_index(sqlite3_stmt*, const char *zName)
    cdef int sqlite3_clear_bindings(sqlite3_stmt*)
    cdef int sqlite3_column_count(sqlite3_stmt *pStmt)
    cdef const char *sqlite3_column_name(sqlite3_stmt*, int N)
    # The following 4 require SQLITE_ENABLE_COLUMN_METADATA compilation flag.
    cdef const char *sqlite3_column_database_name(sqlite3_stmt*,int)
    cdef const char *sqlite3_column_table_name(sqlite3_stmt*,int)
    cdef const char *sqlite3_column_origin_name(sqlite3_stmt*,int)
    cdef const char *sqlite3_column_decltype(sqlite3_stmt*,int)
    #cdef const void *sqlite3_column_name16(sqlite3_stmt*, int N)
    #cdef const void *sqlite3_column_database_name16(sqlite3_stmt*,int)
    #cdef const void *sqlite3_column_table_name16(sqlite3_stmt*,int)
    #cdef const void *sqlite3_column_origin_name16(sqlite3_stmt*,int)
    #cdef const void *sqlite3_column_decltype16(sqlite3_stmt*,int)
    cdef int sqlite3_step(sqlite3_stmt*)
    cdef int sqlite3_data_count(sqlite3_stmt *pStmt)
    cdef const void *sqlite3_column_blob(sqlite3_stmt*, int iCol)
    cdef double sqlite3_column_double(sqlite3_stmt*, int iCol)
    cdef int sqlite3_column_int(sqlite3_stmt*, int iCol)
    cdef sqlite3_int64 sqlite3_column_int64(sqlite3_stmt*, int iCol)
    cdef const unsigned char *sqlite3_column_text(sqlite3_stmt*, int iCol)
    #cdef const void *sqlite3_column_text16(sqlite3_stmt*, int iCol)
    cdef sqlite3_value *sqlite3_column_value(sqlite3_stmt*, int iCol)
    cdef int sqlite3_column_bytes(sqlite3_stmt*, int iCol)
    #cdef int sqlite3_column_bytes16(sqlite3_stmt*, int iCol)
    cdef int sqlite3_column_type(sqlite3_stmt*, int iCol)
    cdef int sqlite3_finalize(sqlite3_stmt *pStmt)
    cdef int sqlite3_reset(sqlite3_stmt *pStmt)
    cdef int sqlite3_create_function(
        sqlite3 *db,
        const char *zFunctionName,
        int nArg,
        int eTextRep,
        void *pApp,
        void (*xFunc)(sqlite3_context*,int,sqlite3_value**),
        void (*xStep)(sqlite3_context*,int,sqlite3_value**),
        void (*xFinal)(sqlite3_context*))
    #cdef int sqlite3_create_function16(sqlite3 *db, const void *zFunctionName, int nArg, int eTextRep, void *pApp, void (*xFunc)(sqlite3_context*,int,sqlite3_value**), void (*xStep)(sqlite3_context*,int,sqlite3_value**), void (*xFinal)(sqlite3_context*))
    cdef int sqlite3_create_function_v2(
        sqlite3 *db,
        const char *zFunctionName,
        int nArg,
        int eTextRep,
        void *pApp,
        void (*xFunc)(sqlite3_context*,int,sqlite3_value**),
        void (*xStep)(sqlite3_context*,int,sqlite3_value**),
        void (*xFinal)(sqlite3_context*),
        void(*xDestroy)(void*))
    cdef int sqlite3_create_window_function(sqlite3 *db, const char *zFunctionName, int nArg, int eTextRep, void *pApp, void (*xStep)(sqlite3_context*,int,sqlite3_value**), void (*xFinal)(sqlite3_context*), void (*xValue)(sqlite3_context*), void (*xInverse)(sqlite3_context*,int,sqlite3_value**), void(*xDestroy)(void*))
    cdef const void *sqlite3_value_blob(sqlite3_value*)
    cdef double sqlite3_value_double(sqlite3_value*)
    cdef int sqlite3_value_int(sqlite3_value*)
    cdef sqlite3_int64 sqlite3_value_int64(sqlite3_value*)
    cdef void *sqlite3_value_pointer(sqlite3_value*, const char*)
    cdef const unsigned char *sqlite3_value_text(sqlite3_value*)
    #cdef const void *sqlite3_value_text16(sqlite3_value*)
    #cdef const void *sqlite3_value_text16le(sqlite3_value*)
    #cdef const void *sqlite3_value_text16be(sqlite3_value*)
    cdef int sqlite3_value_bytes(sqlite3_value*)
    #cdef int sqlite3_value_bytes16(sqlite3_value*)
    cdef int sqlite3_value_type(sqlite3_value*)
    cdef int sqlite3_value_numeric_type(sqlite3_value*)
    cdef int sqlite3_value_nochange(sqlite3_value*)
    cdef int sqlite3_value_frombind(sqlite3_value*)
    cdef unsigned int sqlite3_value_subtype(sqlite3_value*)
    cdef sqlite3_value *sqlite3_value_dup(const sqlite3_value*)
    cdef void sqlite3_value_free(sqlite3_value*)
    cdef void *sqlite3_aggregate_context(sqlite3_context*, int nBytes)
    cdef void *sqlite3_user_data(sqlite3_context*)
    cdef sqlite3 *sqlite3_context_db_handle(sqlite3_context*)
    cdef void *sqlite3_get_auxdata(sqlite3_context*, int N)
    cdef void sqlite3_set_auxdata(sqlite3_context*, int N, void*, void (*)(void*))
    cdef void sqlite3_result_blob(sqlite3_context*, const void*, int, void(*)(void*))
    cdef void sqlite3_result_blob64(sqlite3_context*,const void*, sqlite3_uint64,void(*)(void*))
    cdef void sqlite3_result_double(sqlite3_context*, double)
    cdef void sqlite3_result_error(sqlite3_context*, const char*, int)
    #cdef void sqlite3_result_error16(sqlite3_context*, const void*, int)
    cdef void sqlite3_result_error_toobig(sqlite3_context*)
    cdef void sqlite3_result_error_nomem(sqlite3_context*)
    cdef void sqlite3_result_error_code(sqlite3_context*, int)
    cdef void sqlite3_result_int(sqlite3_context*, int)
    cdef void sqlite3_result_int64(sqlite3_context*, sqlite3_int64)
    cdef void sqlite3_result_null(sqlite3_context*)
    cdef void sqlite3_result_text(sqlite3_context*, const char*, int, void(*)(void*))
    cdef void sqlite3_result_text64(sqlite3_context*, const char*,sqlite3_uint64, void(*)(void*), unsigned char encoding)
    #cdef void sqlite3_result_text16(sqlite3_context*, const void*, int, void(*)(void*))
    #cdef void sqlite3_result_text16le(sqlite3_context*, const void*, int,void(*)(void*))
    #cdef void sqlite3_result_text16be(sqlite3_context*, const void*, int,void(*)(void*))
    cdef void sqlite3_result_value(sqlite3_context*, sqlite3_value*)
    cdef void sqlite3_result_pointer(sqlite3_context*, void*,const char*,void(*)(void*))
    cdef void sqlite3_result_zeroblob(sqlite3_context*, int n)
    cdef int sqlite3_result_zeroblob64(sqlite3_context*, sqlite3_uint64 n)
    cdef void sqlite3_result_subtype(sqlite3_context*,unsigned int)
    cdef int sqlite3_create_collation(
        sqlite3*,
        const char *zName,
        int eTextRep,
        void *pArg,
        int(*xCompare)(void*,int,const void*,int,const void*))
    cdef int sqlite3_create_collation_v2(sqlite3*, const char *zName, int eTextRep, void *pArg, int(*xCompare)(void*,int,const void*,int,const void*), void(*xDestroy)(void*))
    #cdef int sqlite3_create_collation16(sqlite3*, const void *zName, int eTextRep, void *pArg, int(*xCompare)(void*,int,const void*,int,const void*))
    cdef int sqlite3_collation_needed(sqlite3*, void*, void(*)(void*,sqlite3*,int eTextRep,const char*))
    #cdef int sqlite3_collation_needed16(sqlite3*, void*, void(*)(void*,sqlite3*,int eTextRep,const void*))
    #cdef int sqlite3_key(sqlite3 *db, const void *pKey, int nKey)
    #cdef int sqlite3_key_v2(sqlite3 *db, const char *zDbName, const void *pKey, int nKey)
    #cdef int sqlite3_rekey(sqlite3 *db, const void *pKey, int nKey)
    #cdef int sqlite3_rekey_v2(sqlite3 *db, const char *zDbName, const void *pKey, int nKey)
    cdef int sqlite3_sleep(int)
    cdef int sqlite3_get_autocommit(sqlite3*)
    cdef sqlite3 *sqlite3_db_handle(sqlite3_stmt*)
    cdef const char *sqlite3_db_filename(sqlite3 *db, const char *zDbName)
    cdef int sqlite3_db_readonly(sqlite3 *db, const char *zDbName)
    cdef sqlite3_stmt *sqlite3_next_stmt(sqlite3 *pDb, sqlite3_stmt *pStmt)
    cdef void *sqlite3_commit_hook(sqlite3*, int(*)(void*), void*)
    cdef void *sqlite3_rollback_hook(sqlite3*, void(*)(void *), void*)
    cdef void *sqlite3_update_hook(sqlite3*, void(*)(void *,int ,char *,char *,sqlite3_int64), void*)
    cdef int sqlite3_enable_shared_cache(int)
    cdef int sqlite3_release_memory(int)
    cdef int sqlite3_db_release_memory(sqlite3*)
    cdef sqlite3_int64 sqlite3_soft_heap_limit64(sqlite3_int64 N)
    cdef int sqlite3_table_column_metadata(sqlite3 *db, const char *zDbName, const char *zTableName, const char *zColumnName, char **pzDataType, char **pzCollSeq, int *pNotNull, int *pPrimaryKey, int *pAutoinc)
    cdef int sqlite3_load_extension(sqlite3 *db, const char *zFile, const char *zProc, char **pzErrMsg)
    cdef int sqlite3_enable_load_extension(sqlite3 *db, int onoff)
    cdef int sqlite3_auto_extension(void(*xEntryPoint)())
    cdef int sqlite3_cancel_auto_extension(void(*xEntryPoint)())
    cdef void sqlite3_reset_auto_extension()
    cdef int sqlite3_create_module(sqlite3 *db, const char *zName, const sqlite3_module *p, void *pClientData)
    cdef int sqlite3_create_module_v2(sqlite3 *db, const char *zName, const sqlite3_module *p, void *pClientData, void(*xDestroy)(void*))
    cdef int sqlite3_declare_vtab(sqlite3*, const char *zSQL)
    cdef int sqlite3_overload_function(sqlite3*, const char *zFuncName, int nArg)
    cdef int sqlite3_blob_open(sqlite3*, const char *zDb, const char *zTable, const char *zColumn, sqlite3_int64 iRow, int flags, sqlite3_blob **ppBlob)
    cdef int sqlite3_blob_reopen(sqlite3_blob *, sqlite3_int64)
    cdef int sqlite3_blob_close(sqlite3_blob *)
    cdef int sqlite3_blob_bytes(sqlite3_blob *)
    cdef int sqlite3_blob_read(sqlite3_blob *, void *Z, int N, int iOffset)
    cdef int sqlite3_blob_write(sqlite3_blob *, const void *z, int n, int iOffset)
    cdef sqlite3_vfs *sqlite3_vfs_find(const char *zVfsName)
    cdef int sqlite3_vfs_register(sqlite3_vfs*, int makeDflt)
    cdef int sqlite3_vfs_unregister(sqlite3_vfs*)
    cdef sqlite3_mutex *sqlite3_mutex_alloc(int)
    cdef void sqlite3_mutex_free(sqlite3_mutex*)
    cdef void sqlite3_mutex_enter(sqlite3_mutex*)
    cdef int sqlite3_mutex_try(sqlite3_mutex*)
    cdef void sqlite3_mutex_leave(sqlite3_mutex*)
    cdef int sqlite3_mutex_held(sqlite3_mutex*)
    cdef int sqlite3_mutex_notheld(sqlite3_mutex*)
    cdef sqlite3_mutex *sqlite3_db_mutex(sqlite3*)
    cdef int sqlite3_file_control(sqlite3*, const char *zDbName, int op, void*)
    cdef int sqlite3_test_control(int op, ...)
    cdef int sqlite3_keyword_count()
    cdef int sqlite3_keyword_name(int,const char**,int*)
    cdef int sqlite3_keyword_check(const char*,int)
    cdef sqlite3_str *sqlite3_str_new(sqlite3*)
    cdef char *sqlite3_str_finish(sqlite3_str*)
    cdef void sqlite3_str_appendf(sqlite3_str*, const char *zFormat, ...)
    cdef void sqlite3_str_vappendf(sqlite3_str*, const char *zFormat, va_list)
    cdef void sqlite3_str_append(sqlite3_str*, const char *zIn, int N)
    cdef void sqlite3_str_appendall(sqlite3_str*, const char *zIn)
    cdef void sqlite3_str_appendchar(sqlite3_str*, int N, char C)
    cdef void sqlite3_str_reset(sqlite3_str*)
    cdef int sqlite3_str_errcode(sqlite3_str*)
    cdef int sqlite3_str_length(sqlite3_str*)
    cdef char *sqlite3_str_value(sqlite3_str*)
    cdef int sqlite3_status(int op, int *pCurrent, int *pHighwater, int resetFlag)
    cdef int sqlite3_status64(int op, sqlite3_int64 *pCurrent, sqlite3_int64 *pHighwater, int resetFlag)
    cdef int sqlite3_db_status(sqlite3*, int op, int *pCur, int *pHiwtr, int resetFlg)
    cdef int sqlite3_stmt_status(sqlite3_stmt*, int op,int resetFlg)
    cdef sqlite3_backup *sqlite3_backup_init(sqlite3 *pDest, const char *zDestName, sqlite3 *pSource, const char *zSourceName)
    cdef int sqlite3_backup_step(sqlite3_backup *p, int nPage)
    cdef int sqlite3_backup_finish(sqlite3_backup *p)
    cdef int sqlite3_backup_remaining(sqlite3_backup *p)
    cdef int sqlite3_backup_pagecount(sqlite3_backup *p)
    cdef int sqlite3_unlock_notify(sqlite3 *pBlocked, void (*xNotify)(void **apArg, int nArg), void *pNotifyArg)
    cdef int sqlite3_stricmp(const char *, const char *)
    cdef int sqlite3_strnicmp(const char *, const char *, int)
    cdef int sqlite3_strglob(const char *zGlob, const char *zStr)
    cdef int sqlite3_strlike(const char *zGlob, const char *zStr, unsigned int cEsc)
    cdef void sqlite3_log(int iErrCode, const char *zFormat, ...)
    cdef void *sqlite3_wal_hook(sqlite3*, int(*)(void *,sqlite3*,const char*,int), void*)
    cdef int sqlite3_wal_autocheckpoint(sqlite3 *db, int N)
    cdef int sqlite3_wal_checkpoint(sqlite3 *db, const char *zDb)
    cdef int sqlite3_wal_checkpoint_v2(sqlite3 *db, const char *zDb, int eMode, int *pnLog, int *pnCkpt)
    cdef int sqlite3_vtab_config(sqlite3*, int op, ...)
    cdef int sqlite3_vtab_on_conflict(sqlite3 *)
    cdef int sqlite3_vtab_nochange(sqlite3_context*)
    cdef int sqlite3_stmt_scanstatus(sqlite3_stmt *pStmt, int idx, int iScanStatusOp, void *pOut)
    cdef void sqlite3_stmt_scanstatus_reset(sqlite3_stmt*)
    cdef int sqlite3_db_cacheflush(sqlite3*)
    # Requires sqlite be compiled with ENABLE_PREUPDATE_HOOK.
    cdef void *sqlite3_preupdate_hook(
        sqlite3 *db,
        void(*xPreUpdate)(
            void *pCtx,
            sqlite3 *db,
            int op,
            char *zDb,
            char *zName,
            sqlite3_int64 iKey1,
            sqlite3_int64 iKey2),
        void*)
    cdef int sqlite3_preupdate_old(sqlite3 *, int, sqlite3_value **)
    cdef int sqlite3_preupdate_count(sqlite3 *)
    cdef int sqlite3_preupdate_depth(sqlite3 *)
    cdef int sqlite3_preupdate_new(sqlite3 *, int, sqlite3_value **)
    cdef int sqlite3_system_errno(sqlite3*)
    cdef unsigned char *sqlite3_serialize(sqlite3 *db, const char *zSchema, sqlite3_int64 *piSize, unsigned int mFlags)
    cdef int sqlite3_deserialize(sqlite3 *db, const char *zSchema, unsigned char *pData, sqlite3_int64 szDb, sqlite3_int64 szBuf, unsigned mFlags)


cdef int SQLITE_JSON_TYPE = 74  # ASCII 'J', from sqlite/ext/misc/json.c.
