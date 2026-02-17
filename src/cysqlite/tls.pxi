cdef extern from *:
    """
    #include <stddef.h>

    #if defined(_MSC_VER)
    #define CY_THREAD_LOCAL __declspec(thread)
    #elif defined(__GNUC__) || defined(__clang__)
    #define CY_THREAD_LOCAL __thread
    #else
    #error "Thread-local storage not supported."
    #endif

    #define CY_MAX_CB_DEPTH 16

    static CY_THREAD_LOCAL void *_cysqlite_cb_stack[CY_MAX_CB_DEPTH];
    static CY_THREAD_LOCAL int _cysqlite_cb_depth;

    static inline void cysqlite_enter_callback(void *db) {
        if (_cysqlite_cb_depth < CY_MAX_CB_DEPTH) {
            _cysqlite_cb_stack[_cysqlite_cb_depth] = db;
        }
        _cysqlite_cb_depth++;
    }

    static inline void cysqlite_exit_callback(void) {
        if (_cysqlite_cb_depth > 0) {
            _cysqlite_cb_depth--;
        }
    }

    static inline int cysqlite_in_callback(void *db) {
        int i;
        int limit = _cysqlite_cb_depth < CY_MAX_CB_DEPTH ? _cysqlite_cb_depth : CY_MAX_CB_DEPTH;
        for (i = 0; i < limit; i++) {
            if (_cysqlite_cb_stack[i] == db) {
                return 1;
            }
        }
        return 0;
    }
    """
    void cysqlite_enter_callback(void *db) nogil
    void cysqlite_exit_callback() nogil
    int cysqlite_in_callback(void *db) nogil
