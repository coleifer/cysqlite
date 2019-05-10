# cython: language_level=3
from cpython.bytes cimport PyBytes_Check
from cpython.bytes cimport PyBytes_FromStringAndSize
from cpython.object cimport PyObject
from cpython.ref cimport Py_DECREF
from cpython.ref cimport Py_INCREF
from cpython.tuple cimport PyTuple_New
from cpython.tuple cimport PyTuple_SET_ITEM
from cpython.unicode cimport PyUnicode_AsUTF8String
from cpython.unicode cimport PyUnicode_Check
from cpython.unicode cimport PyUnicode_DecodeUTF8

include "sqlite.pxi"


cdef inline str decode(key):
    cdef str ukey
    if PyBytes_Check(key):
        ukey = key.decode('utf-8')
    elif PyUnicode_Check(key):
        ukey = <str>key
    elif key is None:
        return None
    else:
        ukey = str(key)
    return ukey


cdef inline bytes encode(key):
    cdef bytes bkey
    if PyUnicode_Check(key):
        bkey = PyUnicode_AsUTF8String(key)
    elif PyBytes_Check(key):
        bkey = <bytes>key
    elif key is None:
        return None
    else:
        bkey = PyUnicode_AsUTF8String(str(key))
    return bkey


cdef dict _window_functions = {}


cdef sqlite_to_python(int argc, sqlite3_value **params):
    cdef:
        int i
        int vtype
        list pyargs = []

    for i in range(argc):
        vtype = sqlite3_value_type(params[i])
        if vtype == SQLITE_INTEGER:
            pyval = sqlite3_value_int(params[i])
        elif vtype == SQLITE_FLOAT:
            pyval = sqlite3_value_double(params[i])
        elif vtype == SQLITE_TEXT:
            pyval = PyUnicode_DecodeUTF8(
                <const char *>sqlite3_value_text(params[i]),
                <Py_ssize_t>sqlite3_value_bytes(params[i]), NULL)
        elif vtype == SQLITE_BLOB:
            pyval = PyBytes_FromStringAndSize(
                <const char *>sqlite3_value_blob(params[i]),
                <Py_ssize_t>sqlite3_value_bytes(params[i]))
        elif vtype == SQLITE_NULL:
            pyval = None
        else:
            pyval = None

        pyargs.append(pyval)

    return pyargs


cdef set_python_result(sqlite3_context *context, value):
    if value is None:
        sqlite3_result_null(context)
    elif isinstance(value, (int, long)):
        sqlite3_result_int64(context, <sqlite3_int64>value)
    elif isinstance(value, float):
        sqlite3_result_double(context, <double>value)
    elif isinstance(value, str):
        bval = PyUnicode_AsUTF8String(value)
        sqlite3_result_text(
            context,
            <const char *>bval,
            -1,
            <sqlite3_destructor_type>-1)
    elif isinstance(value, bytes):
        sqlite3_result_blob(
            context,
            <void *>(<char *>value),
            -1,
            <sqlite3_destructor_type>-1)
    else:
        sqlite3_result_error(
            context,
            encode('Unsupported type %s' % type(value)),
            -1)


cdef set_python_error(sqlite3_context *context, msg):
    sqlite3_result_error(context, encode(msg), -1)


cdef void _pysqlitex_step_callback(sqlite3_context *context, int argc,
                                    sqlite3_value **params) with gil:
    cdef PyObject **obj_pp

    klass = <object>sqlite3_user_data(context)
    obj_pp = <PyObject **>sqlite3_aggregate_context(context, sizeof(PyObject *))
    if obj_pp[0] == NULL:
        try:
            window_fn = klass()
        except Exception as exc:
            set_python_error(context, ('Error initializing user-defined window'
                                       ' function - %r' % exc))
            return

        obj_pp[0] = <PyObject *>window_fn
        Py_INCREF(window_fn)
    else:
        window_fn = <object>(obj_pp[0])

    try:
        window_fn.step(*sqlite_to_python(argc, params))
    except Exception as exc:
        set_python_error(context, ('Error calling user-defined window function'
                                   ' step() method - %r' % exc))


cdef void _pysqlitex_finalize_callback(sqlite3_context *context) with gil:
    cdef PyObject **obj_pp

    obj_pp = <PyObject **>sqlite3_aggregate_context(context, sizeof(PyObject *))
    window_fn = <object>(obj_pp[0])
    try:
        result = window_fn.finalize()
    except Exception as exc:
        set_python_error(context, ('Error calling user-defined window function'
                                   ' finalize() method - %r' % exc))
    else:
        set_python_result(context, result)
    Py_DECREF(window_fn)


cdef void _pysqlitex_value_callback(sqlite3_context *context) with gil:
    cdef PyObject **obj_pp

    obj_pp = <PyObject **>sqlite3_aggregate_context(context, sizeof(PyObject *))
    window_fn = <object>(obj_pp[0])
    try:
        result = window_fn.value()
    except Exception as exc:
        set_python_error(context, ('Error calling user-defined window function'
                                   ' value() method - %r' % exc))
    else:
        set_python_result(context, result)


cdef void _pysqlitex_inverse_callback(sqlite3_context *context, int argc,
                                      sqlite3_value **params) with gil:
    cdef PyObject **obj_pp

    obj_pp = <PyObject **>sqlite3_aggregate_context(context, sizeof(PyObject *))
    window_fn = <object>(obj_pp[0])

    try:
        window_fn.inverse(*sqlite_to_python(argc, params))
    except Exception as exc:
        set_python_error(context, ('Error calling user-defined window function'
                                   ' inverse() method - %r' % exc))


def create_window_function(conn, klass, name=None, nargs=-1,
                           deterministic=True):
    cdef:
        bytes bname
        int flags = SQLITE_UTF8
        pysqlite_Connection *c = <pysqlite_Connection *>conn
        sqlite3 *db = c.db

    if deterministic:
        flags |= SQLITE_DETERMINISTIC

    name = name or klass.__name__.lower()
    _window_functions[name] = klass

    bname = name.encode('utf8')
    rc = sqlite3_create_window_function(
        db,
        <const char *>bname,
        nargs,
        flags,
        <void *>klass,
        _pysqlitex_step_callback,
        _pysqlitex_finalize_callback,
        _pysqlitex_value_callback,
        _pysqlitex_inverse_callback,
        NULL)

    if rc != SQLITE_OK:
        raise Exception('Error creating window function.')
