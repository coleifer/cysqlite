# cython: language_level=3
import cython
from cpython.bytes cimport PyBytes_AS_STRING
from cpython.bytes cimport PyBytes_AsString
from cpython.bytes cimport PyBytes_AsStringAndSize
from cpython.bytes cimport PyBytes_FromStringAndSize
from cpython.buffer cimport Py_buffer
from cpython.buffer cimport PyBuffer_Release
from cpython.buffer cimport PyBUF_CONTIG
from cpython.buffer cimport PyBUF_CONTIG_RO
from cpython.buffer cimport PyObject_CheckBuffer
from cpython.buffer cimport PyObject_GetBuffer
from cpython.dict cimport PyDict_GetItem
from cpython.dict cimport PyDict_Next
from cpython.float cimport PyFloat_FromDouble
from cpython.long cimport PyLong_FromLongLong
from cpython.mem cimport PyMem_Free
from cpython.mem cimport PyMem_Malloc
from cpython.object cimport PyObject
from cpython.ref cimport Py_DECREF
from cpython.ref cimport Py_INCREF
from cpython.tuple cimport PyTuple_New
from cpython.tuple cimport PyTuple_GET_SIZE
from cpython.tuple cimport PyTuple_SET_ITEM
from cpython.unicode cimport PyUnicode_AsUTF8
from cpython.unicode cimport PyUnicode_AsUTF8AndSize
from cpython.unicode cimport PyUnicode_DecodeUTF8
from cpython.unicode cimport PyUnicode_FromString
from libc.limits cimport INT_MAX
from libc.math cimport log
from libc.math cimport sqrt
from libc.stdint cimport int64_t
from libc.stdlib cimport rand
from libc.string cimport memcpy
from libc.string cimport memset

import datetime
import functools
import inspect
import io as _io
import traceback
import uuid
import weakref
from bisect import bisect_left
from bisect import insort

from cysqlite._cysqlite cimport *
from cysqlite.exceptions import (
    AuthorizationError,
    CheckIntegrityError,
    DatabaseCorruptError,
    DatabaseLockedError,
    DataError,
    DiskFullError,
    ForeignKeyIntegrityError,
    IntegrityError,
    InternalError,
    NotNullIntegrityError,
    NotSupportedError,
    OperationalError,
    PrimaryKeyIntegrityError,
    ProgrammingError,
    ReadOnlyError,
    UniqueIntegrityError)
from cysqlite.metadata import (
    ColumnMetadata,
    Column,
    ForeignKey,
    Index,
    View)

include "./sqlite3.pxi"


cdef int _determine_threadsafety():
    cdef int mode = sqlite3_threadsafe()
    if mode == 0:
        return 0
    elif mode == 1:
        return 3
    return 1

threadsafety = _determine_threadsafety()


# Forward references.
cdef class _Callback(object)
cdef class Statement(object)
cdef class Cursor(object)
cdef class Row(object)
cdef class Transaction(object)
cdef class Savepoint(object)
cdef class Blob(object)
cdef class _TableFunctionImpl(object)


SENTINEL = object()


cdef raise_sqlite_error_sql(Connection conn, unicode msg, unicode sql):
    raise_sqlite_error(conn, f'{msg}[{sql}] ')


cdef raise_sqlite_error(Connection conn, unicode msg):
    cdef:
        int code = 0
        int ext = 0

        sqlite3 *db = conn.db if conn is not None else NULL
        object cause = None

    # If a callback stashed an exception on the connection during this
    # statement, consume it now and chain it as __cause__ on the raised
    # exception. This gives callers the original Python failure site in
    # the traceback while keeping the DB-API-typed exception on the
    # outside for `except OperationalError:` / `except IntegrityError:`.
    if conn is not None and conn._callback_error is not None:
        cause = conn._callback_error
        conn._callback_error = None

    if db != NULL:
        code = sqlite3_errcode(db)
        ext = sqlite3_extended_errcode(db)
        errmsg = decode(sqlite3_errmsg(db))
    else:
        errmsg = '(db handle is NULL)'

    if code == SQLITE_CONSTRAINT:
        if ext == SQLITE_CONSTRAINT_UNIQUE:
            exc = UniqueIntegrityError
        elif ext == SQLITE_CONSTRAINT_NOTNULL:
            exc = NotNullIntegrityError
        elif ext == SQLITE_CONSTRAINT_FOREIGNKEY:
            exc = ForeignKeyIntegrityError
        elif ext == SQLITE_CONSTRAINT_CHECK:
            exc = CheckIntegrityError
        elif ext == SQLITE_CONSTRAINT_PRIMARYKEY:
            exc = PrimaryKeyIntegrityError
        else:
            exc = IntegrityError
    elif code in (SQLITE_RANGE, SQLITE_MISMATCH, SQLITE_TOOBIG):
        exc = DataError
    elif code == SQLITE_READONLY:
        exc = ReadOnlyError
    elif code == SQLITE_FULL:
        exc = DiskFullError
    elif code in (SQLITE_BUSY, SQLITE_LOCKED):
        exc = DatabaseLockedError
    elif code == SQLITE_AUTH:
        exc = AuthorizationError
    elif code in (SQLITE_CORRUPT, SQLITE_NOTADB):
        exc = DatabaseCorruptError
    elif code == SQLITE_MISUSE:
        exc = ProgrammingError
    elif code == SQLITE_INTERNAL:
        exc = InternalError
    elif code == SQLITE_NOMEM:
        exc = MemoryError
    else:
        exc = OperationalError

    raise exc(f"{msg}{errmsg} (code={code}, ext={ext})") from cause


cdef class _callable_context_manager(object):
    def __call__(self, fn):
        @functools.wraps(fn)
        def inner(*args, **kwargs):
            with self:
                return fn(*args, **kwargs)
        return inner

cdef inline check_connection(Connection conn):
    if conn.db == NULL:
        raise OperationalError('Cannot operate on closed database.')

cdef inline unicode _quote_ident(name):
    return '"%s"' % str(name).replace('"', '""')


cdef class Row(object):
    cdef:
        tuple _data
        object _description
        dict _name_map

    def __cinit__(self, Cursor cursor, tuple data):
        self._data = data
        self._description = cursor.description
        self._name_map = None

    cdef _build_name_map(self):
        if self._name_map is None:
            self._name_map = {}
            if self._description:
                for idx, col_desc in enumerate(self._description):
                    col_name = col_desc[0]
                    # Only store reference to first occurrence of name.
                    if col_name not in self._name_map:
                        self._name_map[col_name] = idx

    def __getitem__(self, key):
        if isinstance(key, int):
            return self._data[key]
        elif isinstance(key, str):
            self._build_name_map()
            if key not in self._name_map:
                raise KeyError(f'No column named "{key}"')
            return self._data[self._name_map[key]]
        raise TypeError('__getitem__ accepts index or string key')

    def __contains__(self, key):
        self._build_name_map()
        return key in self._name_map

    def get(self, key, default=None):
        self._build_name_map()
        idx = self._name_map.get(key)
        return self._data[idx] if idx is not None else default

    def __getattr__(self, name):
        if name.startswith('__') and name.endswith('__'):
            raise AttributeError(name)

        self._build_name_map()
        if name not in self._name_map:
            raise AttributeError(f'Row object has no attribute "{name}"')
        return self._data[self._name_map[name]]

    def __iter__(self):
        return iter(self._data)

    def __len__(self):
        return len(self._data)

    def __repr__(self):
        if self._description:
            parts = []
            for idx, col in enumerate(self._description):
                parts.append(f'{col[0]}={self._data[idx]!r}')
            return '<Row(%s)>' % ', '.join(parts)
        else:
            return '<Row(%s)>' % repr(self._data)

    def __eq__(self, other):
        if isinstance(other, Row):
            return self._data == (<Row>other)._data
        elif isinstance(other, tuple):
            return self._data == other
        return NotImplemented

    def __ne__(self, other):
        result = self.__eq__(other)
        if result is NotImplemented:
            return result
        return not result

    def __hash__(self):
        return hash(self._data)

    def keys(self):
        if self._description:
            return [col[0] for col in self._description]
        return []

    def values(self):
        return list(self._data)

    def items(self):
        if self._description:
            return [(col[0], self._data[idx])
                    for idx, col in enumerate(self._description)]
        return []

    def as_dict(self):
        return dict(self.items())


def dict_factory(Cursor cursor, tuple row):
    return {d[0]: v for d, v in zip(cursor.description, row)}


@cython.final
@cython.internal
cdef class Statement(object):
    cdef:
        Connection conn
        sqlite3_stmt *st
        bint is_dml
        unicode sql
        bytes bsql

    def __cinit__(self, Connection conn, unicode sql):
        self.conn = conn
        self.sql = sql
        self.bsql = encode(sql)
        self.st = NULL
        self.is_dml = False
        self.prepare_statement()

    def __dealloc__(self):
        if self.st != NULL:
            sqlite3_finalize(self.st)

    cdef prepare_statement(self):
        cdef:
            const char *tail
            char *zsql
            int rc
            Py_ssize_t nbytes

        PyBytes_AsStringAndSize(self.bsql, &zsql, &nbytes)
        with nogil:
            rc = sqlite3_prepare_v2(self.conn.db, zsql, <int>nbytes,
                                    &(self.st), &tail)

        # When sqlite3_prepare_v2 is called with empty SQL no error is reported
        # but ppStmt will be NULL.
        if rc != SQLITE_OK:
            if self.st:
                sqlite3_finalize(self.st)
                self.st = NULL
            raise_sqlite_error_sql(self.conn, 'error compiling statement: ',
                                   self.sql)

        if self.st == NULL:
            raise ProgrammingError('Empty SQL statement.')

        if self._check_tail(tail):
            sqlite3_finalize(self.st)
            self.st = NULL
            raise ProgrammingError('Can only execute one query at a time.')

        self.is_dml = not sqlite3_stmt_readonly(self.st)

    cdef int _check_tail(self, const char *tail):
        cdef const char* pos = tail
        while pos[0] != 0:
            # Ignore whitespace and semi-colon.
            if not (pos[0] == 32 or pos[0] == 9 or pos[0] == 10 or \
                    pos[0] == 13 or pos[0] == 59):
                return 1
            pos += 1
        return 0

    cdef tuple _convert_dict_to_params(self, dict params, int pc):
        cdef:
            int i
            str bind_name
            const char *zbind_name
            list out = [None] * pc
            PyObject *item

        for i in range(1, pc + 1):
            zbind_name = sqlite3_bind_parameter_name(self.st, i)
            if not zbind_name:
                raise ProgrammingError(f'error: binding {i} has no name')
            bind_name = PyUnicode_FromString(zbind_name + 1)
            if not bind_name:
                raise ProgrammingError(f'error: binding {i} name could not be '
                                       'determined')

            item = PyDict_GetItem(params, bind_name)
            if item is NULL:
                raise OperationalError(f'error: "{bind_name}" parameter not '
                                       'found')
            out[i - 1] = <object>item

        return tuple(out)

    cdef int bind(self, params) except -1:
        cdef:
            const char *buf
            Py_ssize_t nbytes
            Py_buffer view
            bint adapt = bool(self.conn.adapters)
            int i, rc = 0
            int pc
            tuple tparams

        # Get number of params needed.
        pc = sqlite3_bind_parameter_count(self.st)

        # If params were passed as a dict, convert to a list.
        if isinstance(params, tuple):
            tparams = <tuple>params
        elif isinstance(params, dict):
            tparams = self._convert_dict_to_params(params, pc)
        else:
            tparams = tuple(params)

        if pc != PyTuple_GET_SIZE(tparams):
            raise OperationalError(f'error: {pc} parameters required')

        # Note: sqlite3_bind_XXX uses 1-based indexes.
        for i in range(pc):
            param = tparams[i]

            if adapt:
                param_type = type(param)
                if param_type in self.conn.adapters:
                    param = self.conn.adapters[param_type](param)

            if param is None:
                rc = sqlite3_bind_null(self.st, i + 1)
            elif isinstance(param, int):
                rc = sqlite3_bind_int64(self.st, i + 1, param)
            elif isinstance(param, unicode):
                buf = PyUnicode_AsUTF8AndSize(param, &nbytes)
                rc = sqlite3_bind_text64(self.st, i + 1, buf,
                                         <sqlite3_uint64>nbytes,
                                         SQLITE_TRANSIENT,
                                         SQLITE_UTF8)
            elif isinstance(param, float):
                rc = sqlite3_bind_double(self.st, i + 1, param)
            elif isinstance(param, bytes):
                # Faster implementation for bytes vs buffer.
                buf = PyBytes_AS_STRING(param)
                rc = sqlite3_bind_blob64(
                    self.st, i + 1, buf,
                    <sqlite3_uint64>PyBytes_GET_SIZE(param),
                    SQLITE_TRANSIENT)
            elif PyObject_CheckBuffer(param):
                # bytearray, memoryview, (bytes).
                PyObject_GetBuffer(param, &view, PyBUF_CONTIG_RO)
                rc = sqlite3_bind_blob64(self.st, i + 1, view.buf,
                                         <sqlite3_uint64>(view.len),
                                         SQLITE_TRANSIENT)
                PyBuffer_Release(&view)
            elif hasattr(param, '__float__'):
                # Decimal, Fraction, e.g.
                rc = sqlite3_bind_double(self.st, i + 1, float(param))
            else:
                if isinstance(param, datetime.datetime):
                    param = param.isoformat(' ')
                elif isinstance(param, (datetime.date, datetime.time)):
                    param = param.isoformat()
                elif isinstance(param, uuid.UUID):
                    param = str(param)
                else:
                    raise TypeError(
                        'cannot bind parameter %d: type %s is not supported; '
                        'register an adapter to convert it'
                        % (i + 1, type(param).__name__))
                buf = PyUnicode_AsUTF8AndSize(param, &nbytes)
                rc = sqlite3_bind_text64(self.st, i + 1, buf,
                                         <sqlite3_uint64>nbytes,
                                         SQLITE_TRANSIENT,
                                         SQLITE_UTF8)

            if rc != SQLITE_OK:
                sqlite3_clear_bindings(self.st)
                raise_sqlite_error(self.conn,
                                   'error binding parameter %s: ' % param)

        return 0

    cdef int step(self):
        cdef int rc

        with nogil:
            rc = sqlite3_step(self.st)

        return rc

    cdef int reset(self):
        # Cheap calls, not worth a GIL round-trip.
        cdef int rc = sqlite3_reset(self.st)
        sqlite3_clear_bindings(self.st)
        return rc

    cdef int finalize(self):
        sqlite3_finalize(self.st)
        self.st = NULL
        return 0

    cdef list get_row_converters(self, dict mapping):
        cdef:
            const char *decltype
            int i, l, ncols = sqlite3_data_count(self.st)
            list converters = [None] * ncols

        for i in range(ncols):
            decltype = sqlite3_column_decltype(self.st, i)
            if decltype == NULL:
                continue

            l = 0
            while (decltype[l] != 32 and decltype[l] != 0 and
                   decltype[l] != 40):
                l += 1
            if l == 0:
                continue

            name = PyUnicode_DecodeUTF8(decltype, l, NULL)
            if name is None:
                continue

            name = (<str>name).upper()
            if name in mapping:
                converters[i] = mapping[name]

        return converters

    cdef tuple get_row_data(self, list row_converters):
        cdef:
            int i
            int ncols = sqlite3_data_count(self.st)
            tuple result = PyTuple_New(ncols)
            object value
            bint has_converters = (row_converters is not None)

        for i in range(ncols):
            coltype = sqlite3_column_type(self.st, i)
            if coltype == SQLITE_NULL:
                value = None
            elif coltype == SQLITE_INTEGER:
                value = PyLong_FromLongLong(sqlite3_column_int64(self.st, i))
            elif coltype == SQLITE_TEXT:
                nbytes = sqlite3_column_bytes(self.st, i)
                value = PyUnicode_DecodeUTF8(
                    <char *>sqlite3_column_text(self.st, i),
                    nbytes,
                    NULL)
            elif coltype == SQLITE_FLOAT:
                value = PyFloat_FromDouble(sqlite3_column_double(self.st, i))
            elif coltype == SQLITE_BLOB:
                nbytes = sqlite3_column_bytes(self.st, i)
                value = PyBytes_FromStringAndSize(
                    <char *>sqlite3_column_blob(self.st, i),
                    nbytes)
            else:
                raise OperationalError(
                    'error: cannot read column %d: type = %r'
                    % (i, coltype))

            if has_converters and value is not None:
                converter = row_converters[i]
                if converter is not None:
                    value = converter(value)

            # If we were in C we wouldn't need to do this, but Cython sees that
            # we are losing the reference to the object while looping and
            # automatically decrefs it, e.g.:
            # __Pyx_GOTREF(__pyx_t_1);
            # PyTuple_SET_ITEM(__pyx_v_result, __pyx_v_i, __pyx_t_1);
            # __Pyx_DECREF(__pyx_t_1); __pyx_t_1 = 0;
            Py_INCREF(value)

            PyTuple_SET_ITEM(result, i, value)

        return result

    cdef column_count(self):
        return sqlite3_column_count(self.st)

    cdef list columns(self):
        cdef:
            const char *col_name
            int i, col_count = sqlite3_column_count(self.st)
            list accum = [None] * col_count

        for i in range(col_count):
            col_name = sqlite3_column_name(self.st, i)
            col = PyUnicode_FromString(col_name) if col_name != NULL else None
            accum[i] = col
        return accum


@cython.final
cdef class Cursor(object):
    cdef:
        readonly Connection conn
        readonly tuple description
        readonly object lastrowid
        readonly int rowcount
        public object row_factory
        Statement stmt
        bint executing
        int step_status
        list row_converters

    def __cinit__(self, Connection conn):
        self.conn = conn
        self.stmt = None
        self.executing = False
        self.description = None
        self.row_converters = None
        self.row_factory = conn.row_factory

    def __dealloc__(self):
        if self.stmt is not None and self.stmt.st != NULL:
            self.stmt.reset()
            self.conn.stmt_release(self.stmt)
            self.stmt = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.finish()

    cdef set_description(self):
        if self.stmt is None or self.stmt.st == NULL:
            return

        cdef:
            list columns = self.stmt.columns()
            list description = []
            str name

        for name in columns:
            description.append((name,))

        self.description = tuple(description)

    cdef int _start_execute(self) except -1:
        if self.conn.db == NULL:
            self.stmt = None
            self.executing = False
            raise OperationalError('Cannot operate on closed database.')

        if self.executing:
            self.finish()
        return 0

    cpdef execute(self, sql, params=None):
        self._start_execute()

        self.description = None
        self.row_converters = None
        self.rowcount = -1
        self.lastrowid = None

        self.stmt = self.conn.stmt_get(sql)
        try:
            if params is not None:
                self.stmt.bind(params)
            else:
                self.stmt.bind(())
        except Exception:
            self.finish()
            raise

        self.step_status = self.stmt.step()
        if self.step_status == SQLITE_ROW:
            self.executing = True
            self.set_description()
            if self.conn.converters:
                self.row_converters = self.stmt.get_row_converters(
                    self.conn.converters)
        elif self.step_status == SQLITE_DONE:
            # DML with a RETURNING clause has columns even when it produced
            # no rows -- expose the description either way.
            if not self.stmt.is_dml or sqlite3_column_count(self.stmt.st) > 0:
                self.set_description()
        else:
            self.abort()
            raise_sqlite_error_sql(self.conn, 'error executing query: ', sql)

        if self.stmt.is_dml:
            # sqlite3_changes() is reliable at SQLITE_DONE. For DML that
            # returns rows (RETURNING), the count may be partial until the
            # result set is drained, so it's refreshed on every step in
            # _get_current_row().
            self.rowcount = self.conn.changes()
            self.lastrowid = self.conn.last_insert_rowid()

        if self.step_status == SQLITE_DONE:
            self.finish()

        return self

    cpdef executemany(self, sql, seq_of_params=None):
        self._start_execute()

        self.description = None
        self.row_converters = None
        self.rowcount = 0
        self.lastrowid = None
        self.step_status = SQLITE_DONE

        if not seq_of_params:
            return self

        ran = False
        self.stmt = self.conn.stmt_get(sql)
        self.executing = True
        try:
            for params in seq_of_params:
                ran = True
                self.stmt.bind(params)

                self.step_status = self.stmt.step()
                if self.step_status == SQLITE_ROW:
                    self.rowcount = -1
                    raise OperationalError(
                        'executemany() cannot generate results')
                elif self.step_status != SQLITE_DONE:
                    raise_sqlite_error_sql(self.conn,
                                           'error executing query: ', sql)

                self.rowcount = self.rowcount + self.conn.changes()
                self.stmt.reset()
        except Exception:
            self.abort()
            raise

        # Only report lastrowid when something actually executed, otherwise
        # we would report a stale value from a previous statement.
        if ran:
            self.lastrowid = self.conn.last_insert_rowid()
        self.finish()
        return self

    cpdef executescript(self, sql):
        self._start_execute()

        cdef:
            sqlite3_stmt *st
            const char *zsql
            const char *tail
            int rc

        if isinstance(sql, str):
            zsql = PyUnicode_AsUTF8(<str>sql)
        else:
            raise ValueError('sql script must be string')

        tail = zsql

        while True:
            with nogil:
                rc = sqlite3_prepare_v2(self.conn.db, tail, -1, &st, &tail)

            if rc != SQLITE_OK:
                raise_sqlite_error_sql(self.conn, 'error executing query: ',
                                       sql)

            # Prepare succeeds with a NULL statement when the segment is only
            # whitespace, comments or semicolons.
            if st == NULL:
                if tail[0] == 0:
                    break
                continue

            rc = SQLITE_ROW
            while rc == SQLITE_ROW:
                with nogil:
                    rc = sqlite3_step(st)

            if rc != SQLITE_DONE:
                with nogil:
                    sqlite3_finalize(st)
                raise_sqlite_error_sql(self.conn, 'error executing query: ',
                                       sql)

            with nogil:
                rc = sqlite3_finalize(st)
            if rc != SQLITE_OK:
                raise_sqlite_error(self.conn, 'error finalizing: ')

            if tail[0] == 0:
                break

        return self

    cdef tuple _get_current_row(self):
        if self.conn.db == NULL:
            self.executing = False
            raise OperationalError('Cannot operate on closed database.')
        elif self.stmt and self.stmt.st == NULL:
            self.executing = False
            raise OperationalError('Statement was finalized.')
        elif not self.executing:
            raise StopIteration

        cdef tuple row = None

        if self.step_status == SQLITE_ROW:
            try:
                row = self.stmt.get_row_data(self.row_converters)
            finally:
                self.step_status = self.stmt.step()
                # Keep rowcount current for DML+RETURNING so a drained
                # cursor reports the final affected-row count.
                if self.stmt.is_dml:
                    self.rowcount = self.conn.changes()
        elif self.step_status == SQLITE_DONE:
            self.finish()
            raise StopIteration
        else:
            sql = self.stmt.sql
            self.abort()
            raise_sqlite_error_sql(self.conn, 'error executing query: ', sql)

        return row

    def __iter__(self):
        return self

    def __next__(self):
        cdef tuple row = self._get_current_row()
        return self._build_row(row)

    cdef _build_row(self, tuple data):
        if self.row_factory is not None:
            try:
                return self.row_factory(self, data)
            except Exception as exc:
                raise OperationalError(f'row_factory failed: {exc}')
        return data

    cdef finish(self):
        if self.stmt is not None:
            self.stmt.reset()
            self.conn.stmt_release(self.stmt)
            self.stmt = None

        self.executing = False

    cdef abort(self):
        if self.stmt is not None:
            self.stmt.reset()
            self.conn.stmt_in_use.pop(self.stmt, None)
            self.stmt.finalize()
            self.stmt = None

        self.executing = False

    def close(self):
        self.finish()

    cpdef fetchone(self):
        try:
            return self.__next__()
        except StopIteration:
            return

    cpdef fetchmany(self, size):
        accum = []
        try:
            for i in range(size):
                accum.append(self.__next__())
        except StopIteration:
            pass
        return accum

    cpdef fetchall(self):
        return list(self)

    cpdef scalar(self):
        try:
            return self._get_current_row()[0]
        except (IndexError, StopIteration):
            pass
        finally:
            self.finish()

    def columns(self):
        if self.description is None:
            self.set_description()
        if self.description is None:
            return []
        return [row[0] for row in self.description]


@cython.final
cdef class Connection(_callable_context_manager):
    cdef:
        sqlite3 *db
        public bint extensions
        public bint uri
        public int cached_statements
        public int flags
        public float timeout
        public str database
        public str vfs
        public object row_factory
        public bint print_callback_tracebacks
        public object _callback_error
        public dict pragmas

        # List of statements, transactions, savepoints, blob handles?
        bytes _main_db_name
        dict converters  # SQLite decltype -> converter(value).
        dict adapters  # Python type -> adapter(value).
        dict registrations  # (name, nargs, kind) -> (kind, fn, name, nargs...)
        dict callbacks  # (name, nargs, kind) -> wrapper; see _Callback.
        dict stmt_available  # sql -> Statement.
        object stmt_in_use  # In-use Statements, keyed by identity.
        object blob_in_use  # id(blob) -> Blob.
        int _transaction_depth
        _Callback _commit_hook, _rollback_hook, _update_hook, _auth_hook
        _Callback _trace_hook, _progress_hook

    def __init__(self, database, flags=None, timeout=5.0, vfs=None, uri=False,
                 cached_statements=100, extensions=True, row_factory=None,
                 autoconnect=True, pragmas=None, journal_mode=None):
        self.database = decode(database)
        self.flags = flags or 0
        self.timeout = timeout
        self.vfs = vfs
        self.uri = uri
        self.cached_statements = cached_statements
        self.extensions = extensions
        self.row_factory = row_factory
        self.pragmas = dict(pragmas or {})
        if journal_mode is not None:
            self.pragmas.setdefault('journal_mode', journal_mode)
        self.print_callback_tracebacks = False
        self._callback_error = None
        self.converters = {}
        self.adapters = {}

        self.db = NULL
        self.registrations = {}
        self.callbacks = {}
        self.stmt_available = {}
        self.stmt_in_use = {}
        self.blob_in_use = weakref.WeakValueDictionary()
        self._transaction_depth = 0

        if autoconnect:
            self.connect()

    def __dealloc__(self):
        if self.db:
            self._clear_hooks()
            sqlite3_close_v2(self.db)

    cdef _clear_hooks(self):
        # Unregistering is a no-op when nothing is registered, so these run
        # unconditionally.
        sqlite3_trace_v2(self.db, 0, NULL, NULL)
        sqlite3_commit_hook(self.db, NULL, NULL)
        sqlite3_rollback_hook(self.db, NULL, NULL)
        sqlite3_update_hook(self.db, NULL, NULL)
        sqlite3_set_authorizer(self.db, NULL, NULL)
        sqlite3_progress_handler(self.db, 0, NULL, NULL)

    def finalize_statements(self):
        cdef Statement stmt
        for stmt in list(self.stmt_in_use):
            stmt.finalize()
        for stmt in list(self.stmt_available.values()):
            stmt.finalize()

        self.stmt_in_use.clear()
        self.stmt_available.clear()

    def close(self, force=False):
        if self.db == NULL:
            return False

        # Consult the actual connection state, not just the depth counter, so
        # transactions opened manually via begin() are covered as well.
        if self._transaction_depth > 0 or not sqlite3_get_autocommit(self.db):
            if force:
                try:
                    if not sqlite3_get_autocommit(self.db):
                        self.rollback()
                finally:
                    self._transaction_depth = 0
            else:
                raise OperationalError('cannot close database while a '
                                       'transaction is open.')

        # Now that the hooks are unregistered SQLite cannot reach the wrappers,
        # so our references can be dropped. See _Callback.
        self._clear_hooks()
        self._trace_hook = self._commit_hook = self._rollback_hook = None
        self._update_hook = self._auth_hook = self._progress_hook = None

        # Close all blobs.
        for blob in list(self.blob_in_use.values()):
            blob.close()
        self.blob_in_use.clear()

        # Ensure user references to statements cannot be used after the
        # connection has been closed.
        self.finalize_statements()

        # Clear last error.
        self._callback_error = None

        cdef int rc = sqlite3_close_v2(self.db)
        if rc != SQLITE_OK:
            raise InternalError(f'error closing database: {rc}')

        self.db = NULL

        # The closed handle no longer references the UDF/table-function
        # wrappers, so release them. `registrations` is retained in order to
        # replay them on re-connect.
        self.callbacks.clear()
        return True

    def connect(self):
        if self.db: return False

        cdef:
            bytes bdatabase = encode(self.database)
            bytes bvfs
            const char *zdatabase = PyBytes_AsString(bdatabase)
            const char *zvfs = NULL
            int flags = self.flags or (SQLITE_OPEN_READWRITE |
                                       SQLITE_OPEN_CREATE)
            int rc
            int status

        self._transaction_depth = 0

        if self.vfs is not None:
            bvfs = encode(self.vfs)
            zvfs = PyBytes_AsString(bvfs)

        if self.uri or bdatabase.startswith(b'file:'):
            flags |= SQLITE_OPEN_URI

        with nogil:
            rc = sqlite3_open_v2(zdatabase, &self.db, flags, zvfs)

        if rc != SQLITE_OK:
            if self.db == NULL:
                raise MemoryError
            errmsg = decode(sqlite3_errmsg(self.db))
            sqlite3_close_v2(self.db)
            self.db = NULL
            raise OperationalError(f'error opening database: {errmsg}.')

        if self.extensions and HAS_LOAD_EXTENSION:
            rc = sqlite3_db_config(
                self.db,
                SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION,
                1,
                &status)
            if rc != SQLITE_OK:
                errmsg = decode(sqlite3_errmsg(self.db))
                sqlite3_close_v2(self.db)
                self.db = NULL
                raise InternalError(f'could not enable extensions: {errmsg}')

        cdef int timeout_ms = int(self.timeout * 1000)
        rc = sqlite3_busy_timeout(self.db, timeout_ms)
        if rc != SQLITE_OK:
            errmsg = decode(sqlite3_errmsg(self.db))
            sqlite3_close_v2(self.db)
            self.db = NULL
            raise OperationalError(f'error setting busy timeout: {errmsg}')

        if self.pragmas:
            for key, value in self.pragmas.items():
                self.pragma(key, value)

        for (kind, fn, name, n, det) in list(self.registrations.values()):
            if kind == 'tablefunc':
                self._register_table_function(fn)
            else:
                self._register(kind, fn, name, n, det)

        return True

    cpdef is_closed(self):
        return self.db == NULL

    def get_stmt_usage(self):
        return len(self.stmt_available), len(self.stmt_in_use)

    def __enter__(self):
        if not self.db:
            self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if exc_type is not None:
            try:
                self.close(force=True)
            except Exception as exc:
                raise exc_val from exc
        else:
            self.close(force=True)
        return False

    @property
    def callback_error(self):
        exc = self._callback_error
        self._callback_error = None
        return exc

    cdef Statement stmt_get(self, sql):
        cdef Statement st = self.stmt_available.pop(sql, None)
        if st is None:
            st = Statement(self, sql)
        self.stmt_in_use[st] = None
        return st

    cdef stmt_release(self, Statement st):
        if st.st == NULL:
            raise Exception('Cannot release finalized statement.')
        self.stmt_in_use.pop(st, None)
        # We could evict, finalize and replace here, but since the evicted stmt
        # will be garbage-collected automatically it isn't strictly necessary.
        #if st.sql in self.stmt_available:
        #    evicted = <Statement>self.stmt_available.pop(st.sql)
        #    evicted.finalize()
        self.stmt_available[st.sql] = st

        cdef:
            PyObject *key
            PyObject *value
            Py_ssize_t pos = 0

        # Remove oldest statement from the cache.
        if len(self.stmt_available) > self.cached_statements:
            if PyDict_Next(self.stmt_available, &pos, &key, &value):
                evicted = <Statement>self.stmt_available.pop(<object>key)
                evicted.finalize()

    def cursor(self):
        return Cursor(self)

    # The Cursor methods below check the connection is open, no need to here.
    def execute(self, sql, params=None):
        cdef Cursor cursor = Cursor(self)
        return cursor.execute(sql, params)

    def executemany(self, sql, seq_of_params):
        cdef Cursor cursor = Cursor(self)
        return cursor.executemany(sql, seq_of_params)

    def executescript(self, sql):
        cdef Cursor cursor = Cursor(self)
        return cursor.executescript(sql)

    def execute_one(self, sql, params=None):
        cdef Cursor cursor = Cursor(self)
        return cursor.execute(sql, params).fetchone()

    def execute_scalar(self, sql, params=None):
        cdef Cursor cursor = Cursor(self)
        return cursor.execute(sql, params).scalar()

    def execute_simple(self, sql, callback=None):
        check_connection(self)
        cdef:
            bytes bsql = encode(sql)
            char *errmsg
            int rc = 0
            tuple ctx = (callback, self)
            void *userdata = NULL

        if callback is not None:
            # sqlite3_exec is synchronous; the `ctx` local keeps the tuple
            # alive for the duration of the call.
            userdata = <void *>ctx

        rc = sqlite3_exec(self.db, bsql, _exec_callback, userdata, &errmsg)
        if rc != SQLITE_OK:
            if errmsg != NULL:
                sqlite3_free(errmsg)
            raise_sqlite_error(self, 'error executing query: ')

    cdef _execute_internal(self, sql):
        # Internal helper for executing BEGIN/COMMIT/ROLLBACK to avoid
        # unnecessary cursor creation.
        check_connection(self)
        cdef:
            int rc
            Statement stmt
        stmt = self.stmt_get(sql)
        rc = stmt.step()
        if rc == SQLITE_DONE:
            stmt.reset()
            self.stmt_release(stmt)
        else:
            stmt.finalize()
            self.stmt_in_use.pop(stmt, None)
            raise_sqlite_error_sql(self, 'error executing query: ', sql)

    def begin(self, lock=None):
        if lock:
            query = f'BEGIN {lock}'
        else:
            query = 'BEGIN'
        self._execute_internal(query)

    def commit(self):
        self._execute_internal('COMMIT')

    def rollback(self):
        self._execute_internal('ROLLBACK')

    cpdef int changes(self):
        check_connection(self)
        return sqlite3_changes(self.db)

    def total_changes(self):
        check_connection(self)
        return sqlite3_total_changes(self.db)

    cpdef long long last_insert_rowid(self):
        check_connection(self)
        return sqlite3_last_insert_rowid(self.db)

    def interrupt(self):
        check_connection(self)
        sqlite3_interrupt(self.db)

    def autocommit(self):
        check_connection(self)
        return sqlite3_get_autocommit(self.db) != 0

    @property
    def in_transaction(self):
        # A closed connection cannot be in txn, so return False if closed.
        if self.db == NULL:
            return False
        return not sqlite3_get_autocommit(self.db)

    def status(self, flag):
        check_connection(self)
        cdef int current, highwater, rc

        if sqlite3_db_status(self.db, flag, &current, &highwater, 0):
            raise_sqlite_error(self, 'error requesting db status: ')
        return (current, highwater)

    def pragma(self, key, value=SENTINEL, database=None, multi=False,
               permanent=False):
        if permanent and database is not None:
            # Attached databases are not restored by connect(), so a
            # database-qualified pragma cannot be replayed on reconnect.
            raise ValueError('permanent pragmas cannot be database-qualified')
        if database is not None:
            key = f'{_quote_ident(database)}.{key}'
        sql = f'PRAGMA {key}'
        if value is not SENTINEL:
            sql += ' = %s' % (value if value is not None else 0)
            if permanent:
                self.pragmas[key] = value
        elif permanent:
            raise ValueError('permanent pragmas require a value')

        curs = self.execute(sql)
        if multi:
            # Return multiple rows, e.g. PRAGMA table_list.
            return curs
        else:
            # Return a single value, if one was returned.
            row = curs.fetchone()
            return row[0] if row else None

    def get_tables(self, database=None):
        database = _quote_ident(database or 'main')
        stmt = self.execute(f'SELECT name FROM {database}.sqlite_master '
                            'WHERE type=? ORDER BY name', ('table',))
        return [row for row, in stmt]

    def get_views(self, database=None):
        database = _quote_ident(database or 'main')
        sql = (f'SELECT name, sql FROM {database}.sqlite_master WHERE type=? '
               'ORDER BY name')
        return [View(*row) for row in self.execute(sql, ('view',))]

    def get_indexes(self, table, database=None):
        database = _quote_ident(database or 'main')
        query = (f'SELECT name, sql FROM {database}.sqlite_master '
                 'WHERE tbl_name = ? AND type = ? ORDER BY name')
        stmt = self.execute(query, (table, 'index'))
        index_to_sql = dict(stmt)

        # Determine which indexes have a unique constraint.
        unique_indexes = set()
        stmt = self.execute(f'PRAGMA {database}.'
                            f'index_list({_quote_ident(table)})')
        for row in stmt:
            name = row[1]
            is_unique = int(row[2]) == 1
            if is_unique:
                unique_indexes.add(name)

        # Retrieve the indexed columns.
        index_columns = {}
        for index_name in sorted(index_to_sql):
            stmt = self.execute(
                f'PRAGMA {database}.index_info({_quote_ident(index_name)})')
            index_columns[index_name] = [row[2] for row in stmt]

        return [
            Index(
                name,
                index_to_sql[name],
                index_columns[name],
                name in unique_indexes,
                table)
            for name in sorted(index_to_sql)]

    def get_columns(self, table, database=None):
        database = _quote_ident(database or 'main')
        stmt = self.execute(f'PRAGMA {database}.'
                            f'table_info({_quote_ident(table)})')
        return [Column(r[1], r[2], not r[3], bool(r[5]), table, r[4])
                for r in stmt]

    def get_primary_keys(self, table, database=None):
        database = _quote_ident(database or 'main')
        stmt = self.execute(f'PRAGMA {database}.'
                            f'table_info({_quote_ident(table)})')
        return [row[1] for row in filter(lambda r: r[-1], stmt)]

    def get_foreign_keys(self, table, database=None):
        database = _quote_ident(database or 'main')
        stmt = self.execute(f'PRAGMA {database}.'
                            f'foreign_key_list({_quote_ident(table)})')
        return [ForeignKey(row[3], row[2], row[4], table) for row in stmt]

    def table_column_metadata(self, table, column, database=None):
        check_connection(self)
        cdef:
            bytes btable = encode(table)
            bytes bcolumn = encode(column)
            bytes bdatabase
            char *zdatabase = NULL
            char *data_type
            char *coll_seq
            int not_null, primary_key, auto_increment
            int rc

        if database:
            bdatabase = encode(database)
            zdatabase = bdatabase

        rc = sqlite3_table_column_metadata(self.db, zdatabase, btable, bcolumn,
                                           <const char **>&data_type,
                                           <const char **>&coll_seq,
                                           &not_null, &primary_key,
                                           &auto_increment)
        if rc != SQLITE_OK:
            raise_sqlite_error(self, 'error getting column metadata: ')

        # Both outputs may be NULL, e.g. the declared type of an untyped
        # column ("CREATE TABLE t(a)").
        return ColumnMetadata(
            table,
            column,
            decode(data_type) if data_type != NULL else None,
            decode(coll_seq) if coll_seq != NULL else None,
            bool(not_null),
            bool(primary_key),
            bool(auto_increment))

    def transaction(self, lock=None):
        check_connection(self)
        return Transaction(self, lock)

    def savepoint(self, sid=None):
        check_connection(self)
        return Savepoint(self, sid)

    def atomic(self, lock=None):
        check_connection(self)
        return Atomic(self, lock)

    def backup(self, Connection dest, pages=None, name=None, progress=None,
               src_name=None, dest_name=None):
        # src_name is a deprecated alias for name (the source database).
        check_connection(self)
        cdef:
            bytes bsrcname = encode(name or src_name or 'main')
            bytes bdestname = encode(dest_name or 'main')
            int page_step = pages or -1
            int busy_ms = 0
            int timeout_ms = int(self.timeout * 1000)
            int rc = 0
            sqlite3_backup *backup

        if not dest.db:
            raise OperationalError('destination database is closed')

        backup = sqlite3_backup_init(dest.db, bdestname, self.db, bsrcname)
        if backup == NULL:
            raise_sqlite_error(dest, 'error initializing backup: ')

        try:
            while True:
                check_connection(self)
                with nogil:
                    rc = sqlite3_backup_step(backup, page_step)

                if progress is not None:
                    remaining = sqlite3_backup_remaining(backup)
                    page_count = sqlite3_backup_pagecount(backup)
                    progress(remaining, page_count, rc == SQLITE_DONE)

                if rc == SQLITE_BUSY or rc == SQLITE_LOCKED:
                    if busy_ms >= timeout_ms:
                        raise DatabaseLockedError(
                            'backup timed out waiting for lock')
                    with nogil:
                        sqlite3_sleep(250)
                    busy_ms += 250
                elif rc == SQLITE_DONE:
                    break
                elif rc != SQLITE_OK:
                    raise_sqlite_error(dest, 'error backing up database: ')
        finally:
            check_connection(self)
            with nogil:
                rc = sqlite3_backup_finish(backup)

        if rc != SQLITE_OK:
            raise_sqlite_error(dest, 'error backing up database: ')

    def backup_to_file(self, filename, pages=None, name=None, progress=None,
                       src_name=None, dest_name=None):
        cdef Connection dest = Connection(filename)
        try:
            self.backup(dest, pages, name, progress, src_name, dest_name)
        finally:
            dest.close()

    def serialize(self, name='main'):
        check_connection(self)
        if not HAS_DESERIALIZE:
            raise NotSupportedError(
                'this build of SQLite does not support serialize() '
                '(requires SQLite 3.36.0 or newer)')
        cdef:
            bytes bname = encode(name)
            sqlite3_int64 size = 0
            unsigned char *data

        data = cysqlite_serialize(self.db, PyBytes_AsString(bname), &size, 0)
        if data == NULL:
            if size == 0:
                return b''  # Empty database.
            raise MemoryError('sqlite3_serialize failed')
        try:
            return PyBytes_FromStringAndSize(<char *>data, size)
        finally:
            sqlite3_free(data)

    def deserialize(self, data, name='main'):
        check_connection(self)
        if not HAS_DESERIALIZE:
            raise NotSupportedError(
                'this build of SQLite does not support deserialize() '
                '(requires SQLite 3.36.0 or newer)')
        cdef:
            bytes bname = encode(name)
            Py_buffer view
            sqlite3_int64 sz
            unsigned char *buf
            int rc

        if sqlite3_get_autocommit(self.db) == 0:
            raise OperationalError('cannot deserialize: transaction active')

        PyObject_GetBuffer(data, &view, PyBUF_SIMPLE)
        try:
            sz = view.len
            if sz == 0:
                raise ValueError('cannot deserialize an empty buffer')
            buf = <unsigned char *>sqlite3_malloc64(sz)
            if buf == NULL:
                raise MemoryError('sqlite3_malloc64 failed')
            memcpy(buf, view.buf, sz)
        finally:
            PyBuffer_Release(&view)

        rc = cysqlite_deserialize(self.db, PyBytes_AsString(bname),
                                  buf, sz, sz,
                                  SQLITE_DESERIALIZE_FREEONCLOSE |
                                  SQLITE_DESERIALIZE_RESIZEABLE)
        if rc != SQLITE_OK:
            raise_sqlite_error(self, 'error deserializing: ')

    def blob_open(self, table, column, rowid, read_only=False, database=None):
        check_connection(self)
        return Blob(self, table, column, rowid, read_only, database)

    def register_converter(self, data_type, fn):
        self.converters[data_type.upper()] = fn

    def unregister_converter(self, data_type):
        return bool(self.converters.pop(data_type.upper(), None))

    def converter(self, data_type):
        def inner(fn):
            self.register_converter(data_type, fn)
            return fn
        return inner

    def register_adapter(self, python_type, fn):
        self.adapters[python_type] = fn

    def unregister_adapter(self, python_type):
        return bool(self.adapters.pop(python_type, None))

    def adapter(self, python_type):
        def inner(fn):
            self.register_adapter(python_type, fn)
            return fn
        return inner

    def register_type(self, data_type=None, converter=None, python_type=None,
                      adapter=None):
        if data_type is not None:
            self.register_converter(data_type, converter)
        if python_type is not None:
            self.register_adapter(python_type, adapter)

    def load_extension(self, name):
        check_connection(self)
        if not HAS_LOAD_EXTENSION:
            raise NotSupportedError(
                'this build of SQLite does not support loadable extensions '
                '(compiled with SQLITE_OMIT_LOAD_EXTENSION)')
        cdef:
            bytes bname = encode(name)
            char *errmsg
            int rc

        rc = cysqlite_load_extension(self.db, bname, NULL, &errmsg)
        if rc != SQLITE_OK:
            msg = decode(errmsg)
            sqlite3_free(errmsg)
            raise OperationalError(f'error loading extension: {msg}')

    cdef _register(self, kind, fn, name, nargs, deterministic):
        # Register a user-defined scalar/aggregate/window/collation; a fn of
        # None removes the matching registration. The wrapper is owned by
        # self.callbacks and only borrowed by SQLite -- the ownership model
        # and the rules for dropping references are documented on _Callback.
        check_connection(self)
        cdef:
            _Callback callback
            bytes bname = encode(name)
            int flags = SQLITE_UTF8
            int rc = 0

        if kind not in ('function', 'aggregate', 'window', 'collation'):
            raise ValueError('Unrecognized registration kind: %s' % kind)

        if fn is None:
            if kind == 'collation':
                rc = sqlite3_create_collation_v2(
                    self.db, <const char *>bname, SQLITE_UTF8, NULL, NULL,
                    NULL)
                kinds = ('collation',)
            else:
                # Scalar, aggregate and window functions share a registry, so
                # an all-NULL registration removes whichever kind matches.
                rc = sqlite3_create_function_v2(
                    self.db, bname, <int>nargs, flags, NULL, NULL, NULL, NULL,
                    NULL)
                kinds = ('function', 'aggregate', 'window')
            if rc != SQLITE_OK:
                # E.g. SQLITE_BUSY when the function is in active use. SQLite
                # kept the old registration, so keep our references too.
                raise_sqlite_error(self, 'error removing %s: ' % kind)
            for k in kinds:
                self.registrations.pop((name, nargs, k), None)
                self.callbacks.pop((name, nargs, k), None)
            return

        if deterministic:
            flags |= SQLITE_DETERMINISTIC

        callback = _Callback(self, fn)

        if kind == 'function':
            rc = sqlite3_create_function_v2(
                self.db,
                bname,
                <int>nargs,
                flags,
                <void *>callback,
                _function_cb,
                NULL,
                NULL,
                NULL)
        elif kind == 'aggregate':
            rc = sqlite3_create_function_v2(
                self.db,
                bname,
                <int>nargs,
                flags,
                <void *>callback,
                NULL,
                _step_cb,
                _finalize_cb,
                NULL)
        elif kind == 'window':
            rc = sqlite3_create_window_function(
                self.db,
                <const char *>bname,
                <int>nargs,
                flags,
                <void *>callback,
                _step_cb,
                _finalize_cb,
                _value_cb,
                _inverse_cb,
                NULL)
        elif kind == 'collation':
            rc = sqlite3_create_collation_v2(
                self.db,
                <const char *>bname,
                SQLITE_UTF8,
                <void *>callback,
                _collation_cb,
                NULL)

        if rc != SQLITE_OK:
            raise_sqlite_error(self, 'error creating %s: ' % kind)

        # Success: SQLite released any wrapper this replaced, and ours is now
        # the one it borrows (a failed registration must not reach here).
        self.callbacks[(name, nargs, kind)] = callback
        self.registrations[(name, nargs, kind)] = (
            kind,
            fn,
            name,
            nargs,
            deterministic)

    def create_function(self, fn, name=None, nargs=-1, deterministic=True):
        if fn is None and name is None:
            raise ValueError('name is required when removing a function')
        self._register('function', fn, name or fn.__name__, nargs,
                       deterministic)

    def create_aggregate(self, agg, name=None, nargs=-1, deterministic=True):
        if agg is None and name is None:
            raise ValueError('name is required when removing an aggregate')
        self._register('aggregate', agg, name or agg.__name__, nargs,
                       deterministic)

    def create_window_function(self, agg, name=None, nargs=-1,
                               deterministic=True):
        if agg is None and name is None:
            raise ValueError('name is required when removing a window '
                             'function')
        self._register('window', agg, name or agg.__name__, nargs,
                       deterministic)

    def create_collation(self, fn, name=None):
        if fn is None and name is None:
            raise ValueError('name is required when removing a collation')
        self._register('collation', fn, name or fn.__name__, 0, True)

    def create_table_function(self, fn, name=None, columns=None, params=None):
        check_connection(self)
        cls = TableFunction.from_function(fn, name, columns, params)
        cls.register(self)
        return cls

    def table_function(self, name=None, columns=None, params=None):
        def decorator(fn):
            self.create_table_function(fn, name=name, columns=columns,
                                       params=params)
            return fn
        return decorator

    cdef _register_table_function(self, table_function):
        cdef _TableFunctionImpl impl = _TableFunctionImpl(table_function, self)
        impl.create_module(self)
        # The impl is owned here and only borrowed by SQLite, like every
        # other callback wrapper (see _Callback).
        self.callbacks[(impl.name, 0, 'tablefunc')] = impl
        self.registrations[(impl.name, 0, 'tablefunc')] = (
            'tablefunc', table_function, impl.name, 0, False)

    def commit_hook(self, fn):
        check_connection(self)
        if fn is None:
            self._commit_hook = None
            sqlite3_commit_hook(self.db, NULL, NULL)
            return

        cdef _Callback callback = _Callback(self, fn)
        self._commit_hook = callback
        sqlite3_commit_hook(self.db, _commit_cb, <void *>callback)

    def rollback_hook(self, fn):
        check_connection(self)
        if fn is None:
            self._rollback_hook = None
            sqlite3_rollback_hook(self.db, NULL, NULL)
            return
        cdef _Callback callback = _Callback(self, fn)
        self._rollback_hook = callback
        sqlite3_rollback_hook(self.db, _rollback_cb, <void *>callback)

    def update_hook(self, fn):
        check_connection(self)
        if fn is None:
            self._update_hook = None
            sqlite3_update_hook(self.db, NULL, NULL)
            return

        cdef _Callback callback = _Callback(self, fn)
        self._update_hook = callback
        sqlite3_update_hook(self.db, _update_cb, <void *>callback)

    def authorizer(self, fn):
        check_connection(self)
        cdef:
            _Callback callback
            int rc

        if fn is None:
            self._auth_hook = None
            rc = sqlite3_set_authorizer(self.db, NULL, NULL)
        else:
            callback = _Callback(self, fn)
            self._auth_hook = callback
            rc = sqlite3_set_authorizer(self.db, _auth_cb, <void *>callback)

        if rc != SQLITE_OK:
            raise_sqlite_error(self, 'error setting authorizer: ')

    def trace(self, fn, mask=2, expand_sql=True):
        check_connection(self)
        cdef:
            _Callback callback
            int rc

        if fn is None:
            self._trace_hook = None
            rc = sqlite3_trace_v2(self.db, 0, NULL, NULL)
        else:
            callback = _Callback(self, fn, {'expand_sql': expand_sql})
            self._trace_hook = callback
            rc = sqlite3_trace_v2(self.db, mask, _trace_cb, <void *>callback)

        if rc != SQLITE_OK:
            raise_sqlite_error(self, 'error setting trace: ')

    def progress(self, fn, n=1):
        check_connection(self)
        cdef:
            _Callback callback
            int rc

        if fn is None:
            self._progress_hook = None
            sqlite3_progress_handler(self.db, 0, NULL, NULL)
        else:
            callback = _Callback(self, fn)
            self._progress_hook = callback
            sqlite3_progress_handler(self.db, n, _progress_cb,
                                     <void *>callback)

    def set_busy_handler(self, timeout=5.0):
        check_connection(self)
        self.timeout = timeout
        cdef sqlite3_int64 n = int(self.timeout * 1000)
        sqlite3_busy_handler(self.db, _aggressive_busy_handler, <void *>n)

    def enable_load_extension(self, enabled=True):
        check_connection(self)
        if not HAS_LOAD_EXTENSION:
            raise NotSupportedError(
                'this build of SQLite does not support loadable extensions '
                '(compiled with SQLITE_OMIT_LOAD_EXTENSION)')
        cdef int rc = cysqlite_enable_load_extension(self.db, enabled)
        if rc != SQLITE_OK:
            raise_sqlite_error(self, 'error calling enable_load_extension: ')
        return enabled

    def optimize(self, debug=False, run_tables=True, set_limit=True,
                 check_table_sizes=False, dry_run=False):
        if dry_run:
            mode = -1
        else:
            mode = 0
            if debug: mode |= 0x01
            if run_tables: mode |= 0x02
            if set_limit: mode |= 0x10
            if check_table_sizes: mode |= 0x10000
        return self.execute('pragma optimize=%d' % mode)

    def attach(self, str filename, str name):
        check_connection(self)
        self.execute_one('attach database ? as ?', (filename, name))

    def detach(self, str name):
        check_connection(self)
        self.execute_one('detach database ?', (name,))

    def database_list(self):
        check_connection(self)
        return [(row[1], row[2])
                for row in self.execute('pragma database_list')]

    def set_main_db_name(self, name):
        check_connection(self)
        self._main_db_name = encode(name)  # SQLite does not copy, keep ours.
        cdef bytes bname = self._main_db_name
        if sqlite3_db_config(self.db, SQLITE_DBCONFIG_MAINDBNAME,
                             <const char *>bname) != SQLITE_OK:
            raise_sqlite_error(self, 'error setting main db name: ')

    def db_config(self, op, setting=None):
        check_connection(self)
        cdef:
            int rc, status
            int iop = int(op)
            int isetting = -1 if setting is None else int(setting)

        rc = sqlite3_db_config(self.db, iop, isetting, &status)
        if rc != SQLITE_OK:
            raise_sqlite_error(self, 'error setting config value: ')
        return status

    def set_foreign_keys_enabled(self, int enabled):
        return self.db_config(SQLITE_DBCONFIG_ENABLE_FKEY, enabled)
    def get_foreign_keys_enabled(self):
        return self.db_config(SQLITE_DBCONFIG_ENABLE_FKEY)
    def set_triggers_enabled(self, int enabled):
        return self.db_config(SQLITE_DBCONFIG_ENABLE_TRIGGER, enabled)
    def get_triggers_enabled(self):
        return self.db_config(SQLITE_DBCONFIG_ENABLE_TRIGGER)
    def set_load_extension(self, int enabled):
        if not HAS_LOAD_EXTENSION:
            raise NotSupportedError(
                'this build of SQLite does not support loadable extensions')
        return self.db_config(SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, enabled)
    def get_load_extension(self):
        if not HAS_LOAD_EXTENSION:
            raise NotSupportedError(
                'this build of SQLite does not support loadable extensions')
        return self.db_config(SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION)
    def set_shared_cache(self, int enabled):
        check_connection(self)
        cdef int rc = sqlite3_enable_shared_cache(enabled)
        if rc != SQLITE_OK:
            raise_sqlite_error(self, 'error setting shared cache: ')
        return enabled

    def set_autocheckpoint(self, int n):
        check_connection(self)
        if sqlite3_wal_autocheckpoint(self.db, n) != SQLITE_OK:
            raise_sqlite_error(self, 'error setting wal autocheckpoint: ')

    def checkpoint(self, full=False, truncate=False, restart=False, name=None):
        check_connection(self)
        cdef:
            bytes bname
            const char *zDb = NULL
            int mode = SQLITE_CHECKPOINT_PASSIVE
            int pnLog, pnCkpt  # Size of WAL in frames, total num checkpointed.
            int rc

        if full + truncate + restart > 1:
            raise ValueError('full, truncate and restart are mutually '
                             'exclusive.')
        elif full:
            mode = SQLITE_CHECKPOINT_FULL
        elif truncate:
            mode = SQLITE_CHECKPOINT_TRUNCATE
        elif restart:
            mode = SQLITE_CHECKPOINT_RESTART

        if name:
            bname = encode(name)
            zDb = bname

        with nogil:
            rc = sqlite3_wal_checkpoint_v2(self.db, zDb, mode, &pnLog, &pnCkpt)

        if rc == SQLITE_MISUSE:
            raise OperationalError('error: misuse - cannot perform checkpoint')
        elif rc != SQLITE_OK:
            raise_sqlite_error(self, 'error performing checkpoint: ')

        return (pnLog, pnCkpt)

    def setlimit(self, category, int limit):
        check_connection(self)
        rc = sqlite3_limit(self.db, category, limit)
        if rc < 0:
            raise ProgrammingError('category is out of bounds')
        return rc
    def getlimit(self, category):
        return self.setlimit(category, -1)

    def file_control(self, int op, int val, name=None):
        check_connection(self)
        cdef:
            bytes bname
            const char *zDb = NULL

        if name:
            bname = encode(name)
            zDb = bname

        with nogil:
            rc = sqlite3_file_control(self.db, zDb, <int>op, &val)

        if rc != SQLITE_OK:
            raise_sqlite_error(self, 'error in file control: ')

        return val


cdef class _Callback(object):
    # Wrapper handed to SQLite (as the user-data / context pointer) for every
    # registered hook, UDF and collation; it references the Connection so
    # callbacks can stash errors on it (_callback_error).
    #
    # Ownership model: the Connection owns every wrapper it hands to SQLite
    # -- hooks via the _commit_hook/_trace_hook/... attributes, UDFs and
    # collations via the `callbacks` dict (_TableFunctionImpl follows the
    # same model). SQLite only *borrows* the pointer: nothing is INCREF'd on
    # its behalf and no xDestroy destructor is registered. If SQLite owned
    # the only reference, the conn <-> wrapper cycle would be invisible to
    # the cyclic GC and an unclosed Connection could never be collected.
    #
    # Invariant: a wrapper reference may only be dropped (attribute cleared,
    # dict entry popped or overwritten) once SQLite can no longer use the
    # pointer: after a *successful* re-registration or removal (SQLite
    # refuses both with SQLITE_BUSY while the object is in active use), or
    # after sqlite3_close_v2() has succeeded.
    cdef:
        Connection conn
        object fn
        dict settings

    def __cinit__(self, Connection conn, fn, settings=None):
        self.conn = conn
        self.fn = fn
        self.settings = settings


cdef inline void _capture_exc(Connection conn, object exc) noexcept:
    # Stash the exception on the connection so raise_sqlite_error can chain it
    # as __cause__ on the error reported to the caller.
    conn._callback_error = exc
    if conn.print_callback_tracebacks:
        traceback.print_exc()


cdef void _function_cb(sqlite3_context *ctx, int argc, sqlite3_value **argv) noexcept with gil:
    cdef:
        _Callback cb = <_Callback>sqlite3_user_data(ctx)
        tuple params

    # Argument and result conversion happens inside the try so that
    # conversion errors are reported via sqlite3_result_error rather than
    # escaping this noexcept callback (which would leave the result NULL).
    try:
        params = sqlite_to_python(argc, argv)
        result = cb.fn(*params)
        python_to_sqlite(ctx, result)
    except Exception as exc:
        _capture_exc(cb.conn, exc)
        sqlite3_result_error(ctx, b'error in user-defined function', -1)


ctypedef struct aggregate_ctx:
    int in_use
    PyObject *wrapper

cdef class _AggregateWrapper(object):
    cdef:
        object aggregate
        Connection conn

    def __cinit__(self, aggregate, conn):
        self.aggregate = aggregate
        self.conn = conn


cdef _AggregateWrapper get_aggregate(sqlite3_context *ctx):
    cdef:
        aggregate_ctx *agg_ctx = <aggregate_ctx *>sqlite3_aggregate_context(ctx, sizeof(aggregate_ctx))

    if not agg_ctx:
        sqlite3_result_error_nomem(ctx)
        return

    if agg_ctx.in_use:
        return <object>agg_ctx.wrapper  # Borrowed.

    cdef _Callback cb = <_Callback>sqlite3_user_data(ctx)

    try:
        aggregate = cb.fn()  # Create aggregate instance.
    except Exception as exc:
        _capture_exc(cb.conn, exc)
        sqlite3_result_error(ctx, b'error in user-defined aggregate', -1)
        return

    wrapper = _AggregateWrapper(aggregate, cb.conn)

    Py_INCREF(wrapper)  # Owned.
    agg_ctx.in_use = 1
    agg_ctx.wrapper = <PyObject *>wrapper
    return wrapper


cdef void _step_cb(sqlite3_context *ctx, int argc, sqlite3_value **argv) noexcept with gil:
    cdef:
        _AggregateWrapper wrapper
        tuple params

    # Get the aggregate instance, creating it if this is the first call.
    wrapper = get_aggregate(ctx)
    if not wrapper:
        return

    try:
        params = sqlite_to_python(argc, argv)
        wrapper.aggregate.step(*params)
    except Exception as exc:
        _capture_exc(wrapper.conn, exc)
        sqlite3_result_error(ctx, b'error in user-defined aggregate', -1)


cdef void _finalize_cb(sqlite3_context *ctx) noexcept with gil:
    cdef aggregate_ctx *agg_ctx = <aggregate_ctx *>sqlite3_aggregate_context(ctx, 0)

    if not agg_ctx or not agg_ctx.in_use:
        sqlite3_result_null(ctx)
        return

    wrapper = <_AggregateWrapper>agg_ctx.wrapper
    try:
        result = wrapper.aggregate.finalize()
        python_to_sqlite(ctx, result)
    except Exception as exc:
        _capture_exc(wrapper.conn, exc)
        sqlite3_result_error(ctx, b'error in user-defined aggregate', -1)

    Py_DECREF(wrapper)  # Match incref.
    agg_ctx.in_use = 0
    agg_ctx.wrapper = NULL


cdef void _value_cb(sqlite3_context *ctx) noexcept with gil:
    cdef:
        _AggregateWrapper wrapper

    # Get the aggregate instance, creating it if this is the first call.
    wrapper = get_aggregate(ctx)
    if not wrapper:
        return

    try:
        result = wrapper.aggregate.value()
        python_to_sqlite(ctx, result)
    except Exception as exc:
        _capture_exc(wrapper.conn, exc)
        sqlite3_result_error(ctx, b'error in user-defined window function', -1)


cdef void _inverse_cb(sqlite3_context *ctx, int argc, sqlite3_value **params) noexcept with gil:
    cdef:
        _AggregateWrapper wrapper

    # Get the aggregate instance, creating it if this is the first call.
    wrapper = get_aggregate(ctx)
    if not wrapper:
        return

    try:
        wrapper.aggregate.inverse(*sqlite_to_python(argc, params))
    except Exception as exc:
        _capture_exc(wrapper.conn, exc)
        sqlite3_result_error(ctx, b'error in user-defined window function', -1)


cdef int _collation_cb(void *data, int n1, const void *data1,
                       int n2, const void *data2) noexcept with gil:
    cdef:
        _Callback cb = <_Callback>data
        int result = 0

    str1 = PyUnicode_DecodeUTF8(<const char *>data1, n1, "replace")
    str2 = PyUnicode_DecodeUTF8(<const char *>data2, n2, "replace")
    if str1 is None or str2 is None:
        return result

    try:
        result = cb.fn(str1, str2)
    except Exception as exc:
        _capture_exc(cb.conn, exc)
        return 0

    if result > 0:
        return 1
    elif result < 0:
        return -1
    return 0


cdef int _commit_cb(void *data) noexcept with gil:
    # C-callback that delegates to the Python commit handler. If the Python
    # function returns a truthy value or raises an exception, the COMMIT is
    # converted into a ROLLBACK (matching the stdlib sqlite3 behavior).
    cdef _Callback cb = <_Callback>data

    try:
        if cb.fn():
            return SQLITE_ERROR
    except Exception as exc:
        _capture_exc(cb.conn, exc)
        return SQLITE_ERROR

    return SQLITE_OK


cdef void _rollback_cb(void *data) noexcept with gil:
    # C-callback that delegates to the Python rollback handler.
    cdef _Callback cb = <_Callback>data

    try:
        cb.fn()
    except Exception as exc:
        _capture_exc(cb.conn, exc)


cdef void _update_cb(void *data, int queryType, const char *database,
                     const char *table, sqlite3_int64 rowid) noexcept with gil:
    # C-callback that delegates to a Python function that is executed whenever
    # the database is updated (insert/update/delete queries). The Python
    # callback receives a string indicating the query type, the name of the
    # database, the name of the table being updated, and the rowid of the row
    # being updated.
    cdef _Callback cb = <_Callback>data
    if queryType == SQLITE_INSERT:
        query = 'INSERT'
    elif queryType == SQLITE_UPDATE:
        query = 'UPDATE'
    elif queryType == SQLITE_DELETE:
        query = 'DELETE'
    else:
        query = ''

    try:
        cb.fn(query, decode(database), decode(table), <long long>rowid)
    except Exception as exc:
        _capture_exc(cb.conn, exc)


cdef int _auth_cb(void *data, int op, const char *p1, const char *p2,
                  const char *p3, const char *p4) noexcept with gil:
    # Return SQLITE_OK to allow.
    # SQLITE_IGNORE allows compilation but disallows the specific action.
    # SQLITE_DENY prevents compilation completely.
    # Params 3 and 4 are provided by the following table.
    # Param 5 is the database name ("main", "temp", if applicable).
    # Param 6 is the inner-most trigger or view that is responsible for the
    # access attempt, or NULL if from top-level SQL code.
    #
    # SQLITE_CREATE_INDEX          1   Index Name      Table Name
    # SQLITE_CREATE_TABLE          2   Table Name      NULL
    # SQLITE_CREATE_TEMP_INDEX     3   Index Name      Table Name
    # SQLITE_CREATE_TEMP_TABLE     4   Table Name      NULL
    # SQLITE_CREATE_TEMP_TRIGGER   5   Trigger Name    Table Name
    # SQLITE_CREATE_TEMP_VIEW      6   View Name       NULL
    # SQLITE_CREATE_TRIGGER        7   Trigger Name    Table Name
    # SQLITE_CREATE_VIEW           8   View Name       NULL
    # SQLITE_DELETE                9   Table Name      NULL
    # SQLITE_DROP_INDEX           10   Index Name      Table Name
    # SQLITE_DROP_TABLE           11   Table Name      NULL
    # SQLITE_DROP_TEMP_INDEX      12   Index Name      Table Name
    # SQLITE_DROP_TEMP_TABLE      13   Table Name      NULL
    # SQLITE_DROP_TEMP_TRIGGER    14   Trigger Name    Table Name
    # SQLITE_DROP_TEMP_VIEW       15   View Name       NULL
    # SQLITE_DROP_TRIGGER         16   Trigger Name    Table Name
    # SQLITE_DROP_VIEW            17   View Name       NULL
    # SQLITE_INSERT               18   Table Name      NULL
    # SQLITE_PRAGMA               19   Pragma Name     1st arg or NULL
    # SQLITE_READ                 20   Table Name      Column Name
    # SQLITE_SELECT               21   NULL            NULL
    # SQLITE_TRANSACTION          22   Operation       NULL
    # SQLITE_UPDATE               23   Table Name      Column Name
    # SQLITE_ATTACH               24   Filename        NULL
    # SQLITE_DETACH               25   Database Name   NULL
    # SQLITE_ALTER_TABLE          26   Database Name   Table Name
    # SQLITE_REINDEX              27   Index Name      NULL
    # SQLITE_ANALYZE              28   Table Name      NULL
    # SQLITE_CREATE_VTABLE        29   Table Name      Module Name
    # SQLITE_DROP_VTABLE          30   Table Name      Module Name
    # SQLITE_FUNCTION             31   NULL            Function Name
    # SQLITE_SAVEPOINT            32   Operation       Savepoint Name
    # SQLITE_COPY                  0   <not used>
    # SQLITE_RECURSIVE            33   NULL            NULL
    cdef:
        _Callback cb = <_Callback>data
        int rc
        str s1 = decode(p1) if p1 != NULL else None
        str s2 = decode(p2) if p2 != NULL else None
        str s3 = decode(p3) if p3 != NULL else None
        str s4 = decode(p4) if p4 != NULL else None

    try:
        rc = cb.fn(op, s1, s2, s3, s4)
    except Exception as exc:
        _capture_exc(cb.conn, exc)
        rc = SQLITE_ERROR
    return rc


cdef int _trace_cb(unsigned event, void *data, void *p, void *x) noexcept with gil:
    cdef:
        _Callback cb = <_Callback>data
        bint expand_sql = cb.settings['expand_sql']
        char *zsql
        long long sid = -1
        int64_t ns = -1
        unicode sql = None
    # Integer return value is currently ignored, but this may change in future
    # versions of sqlite3.
    # SQLITE_TRACE_STMT invoked when a prepared stmt first begins running. P is
    # a pointer to the statement, X is a pointer to the string of the SQL.
    # SQLITE_TRACE_PROFILE - P points to a statement, X points to a 64-bit
    # integer which is the estimated number of ns that the statement took to
    # run.
    # SQLITE_TRACE_ROW invoked when a statement generates a single row of
    # results. P is a pointer to the statement, X is unused.
    # SQLITE_TRACE_CLOSE is invoked when a database connection closes. P is a
    # pointer to the db conn, X is unused.
    if event != SQLITE_TRACE_CLOSE:
        sid = <long long>p  # Memory address of statement.
        if expand_sql:
            zsql = sqlite3_expanded_sql(<sqlite3_stmt *>p)
        else:
            zsql = <char *>sqlite3_sql(<sqlite3_stmt *>p)
        if zsql is not NULL:
            sql = decode(zsql)
            if expand_sql:
                sqlite3_free(zsql)

    if event == SQLITE_TRACE_PROFILE:
        ns = (<int64_t *>x)[0]

    try:
        cb.fn(event, sid, sql, ns)
    except Exception as exc:
        _capture_exc(cb.conn, exc)
        # NOTE: Sqlite ignores non-zero return values but this may change in
        # the future. Currently they advise returning 0.
        # return SQLITE_ERROR

    return SQLITE_OK


cdef int _progress_cb(void *data) noexcept with gil:
    cdef _Callback cb = <_Callback>data
    # If returns non-zero, the operation is interrupted.
    try:
        return 1 if cb.fn() else 0
    except Exception as exc:
        _capture_exc(cb.conn, exc)
        return SQLITE_OK


cdef int _exec_callback(void *data, int argc, char **argv, char **colnames) noexcept with gil:
    cdef:
        int i
        object callback

    if data == NULL:
        # If no callback given, just return.
        return SQLITE_OK

    callback, conn = <tuple>data
    row = tuple([decode(argv[i]) if argv[i] != NULL else None
                 for i in range(argc)])
    try:
        callback(row)
    except Exception as exc:
        _capture_exc(conn, exc)
        return SQLITE_ERROR

    return SQLITE_OK


cdef class Transaction(_callable_context_manager):
    cdef:
        Connection conn
        str lock

    def __init__(self, Connection conn, lock=None):
        self.conn = conn
        self.lock = lock

    def _begin(self):
        self.conn.begin(self.lock)

    def commit(self, begin=True):
        self.conn.commit()
        if begin: self._begin()

    def rollback(self, begin=True):
        self.conn.rollback()
        if begin: self._begin()

    def __enter__(self):
        if self.conn._transaction_depth < 1:
            self._begin()
        self.conn._transaction_depth += 1
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if not self.conn.db:
            return

        is_bottom = self.conn._transaction_depth == 1

        try:
            if exc_type:
                # If there are still more transactions on the stack, then we
                # will begin a new transaction.
                try:
                    self.rollback(not is_bottom)
                except Exception as exc:
                    raise exc_val from exc
            elif is_bottom and not sqlite3_get_autocommit(self.conn.db):
                try:
                    self.commit(False)
                except Exception:
                    self.rollback(False)
                    raise
        finally:
            self.conn._transaction_depth -= 1


cdef class Savepoint(_callable_context_manager):
    cdef:
        Connection conn
        object quoted_sid
        object sid

    def __init__(self, Connection conn, sid=None):
        self.conn = conn
        self.sid = sid or 's' + uuid.uuid4().hex
        self.quoted_sid = _quote_ident(self.sid)

    def _begin(self):
        self.conn._execute_internal(f'SAVEPOINT {self.quoted_sid}')

    def commit(self, begin=True):
        self.conn._execute_internal(f'RELEASE SAVEPOINT {self.quoted_sid}')
        if begin: self._begin()

    def rollback(self):
        self.conn._execute_internal(f'ROLLBACK TO SAVEPOINT {self.quoted_sid}')

    def __enter__(self):
        self._begin()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if not self.conn.db:
            return

        if exc_type:
            try:
                self.rollback()
            except Exception as exc:
                raise exc_val from exc
        else:
            try:
                self.commit(begin=False)
            except Exception:
                self.rollback()
                raise


cdef class Atomic(_callable_context_manager):
    cdef:
        Connection conn
        str lock
        readonly object txn

    def __init__(self, Connection conn, lock=None):
        self.conn = conn
        self.lock = lock

    def __enter__(self):
        # Use a savepoint when any transaction is already open -- including
        # one started manually via begin() -- otherwise BEGIN would fail.
        if self.conn._transaction_depth == 0 and not self.conn.in_transaction:
            self.txn = self.conn.transaction(self.lock)
        else:
            self.txn = self.conn.savepoint()
        return self.txn.__enter__()

    def __exit__(self, exc_type, exc_val, exc_tb):
        return self.txn.__exit__(exc_type, exc_val, exc_tb)

    def commit(self, begin=True):
        self.txn.commit(begin)

    def rollback(self):
        self.txn.rollback()


cdef inline int _check_blob(Blob blob) except -1:
    if blob.blob == NULL:
        raise ValueError('Cannot operate on closed blob.')
    check_connection(blob.conn)
    return 0


cdef inline bytes _blob_read(Blob blob, int length, int offset):
    # A failed read closes the handle, leaving the blob unusable.
    cdef bytes buf = PyBytes_FromStringAndSize(NULL, length)
    if sqlite3_blob_read(blob.blob, PyBytes_AS_STRING(buf), length, offset):
        blob._close()
        raise_sqlite_error(blob.conn, 'error reading from blob: ')
    return buf


cdef class Blob(object):
    cdef:
        int offset
        bint _read_only
        Connection conn
        sqlite3_blob *blob
        object __weakref__

    def __init__(self, Connection conn, table, column, rowid,
                 read_only=False, database=None):
        cdef:
            bytes btable = encode(table)
            bytes bcolumn = encode(column)
            bytes bdatabase = encode(database or 'main')
            int flags = 0 if read_only else 1
            int rc
            sqlite3_blob *blob

        check_connection(conn)

        self.conn = conn
        self._read_only = read_only

        rc = sqlite3_blob_open(
            self.conn.db,
            <const char *>bdatabase,
            <const char *>btable,
            <const char *>bcolumn,
            <sqlite3_int64>rowid,
            flags,
            &blob)

        if rc != SQLITE_OK:
            raise_sqlite_error(
                self.conn,
                f'Unable to open blob "{table}"."{column}" row {rowid}: ')
        if blob == NULL:
            raise MemoryError('Unable to allocate blob.')

        self.blob = blob
        self.offset = 0
        self.conn.blob_in_use[id(self)] = self

    cdef _close(self):
        if self.blob != NULL:
            sqlite3_blob_close(self.blob)
            self.blob = NULL
            self.conn.blob_in_use.pop(id(self), None)

    def __dealloc__(self):
        self._close()

    @property
    def closed(self):
        return self.blob == NULL

    def close(self):
        self._close()

    def reopen(self, rowid):
        _check_blob(self)
        if sqlite3_blob_reopen(self.blob, <sqlite3_int64>rowid):
            self._close()
            raise_sqlite_error(self.conn, 'unable to reopen blob: ')
        self.offset = 0

    def __enter__(self):
        _check_blob(self)
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
        return False

    def fileno(self):
        raise _io.UnsupportedOperation('fileno')

    def flush(self):
        pass

    def isatty(self):
        return False

    def readable(self):
        return True

    def writable(self):
        return not self._read_only

    def seekable(self):
        return True

    def truncate(self, size=None):
        raise _io.UnsupportedOperation('truncate')

    def __iter__(self):
        return self

    def __next__(self):
        _check_blob(self)
        line = self.readline()
        if not line:
            raise StopIteration
        return line

    def readline(self, size=-1):
        _check_blob(self)
        cdef:
            int remaining = sqlite3_blob_bytes(self.blob) - self.offset
            int limit, n_read, i
            bytes chunk
            char *p

        if remaining == 0:
            return b''

        if size < 0 or size > remaining:
            limit = remaining
        else:
            limit = size

        if limit == 0:
            return b''

        chunk = _blob_read(self, limit, self.offset)
        p = PyBytes_AS_STRING(chunk)

        n_read = limit
        for i in range(limit):
            if p[i] == 10:
                n_read = i + 1  # Include newline.
                break

        self.offset += n_read
        return chunk if n_read == limit else chunk[:n_read]

    def readlines(self, hint=-1):
        _check_blob(self)
        cdef:
            list lines = []
            int total = 0

        while True:
            line = self.readline()
            if not line:
                break
            lines.append(line)
            total += len(line)
            if hint >= 0 and total >= hint:
                break

        return lines

    def writelines(self, lines):
        _check_blob(self)
        if self._read_only:
            raise _io.UnsupportedOperation('write')
        cdef int n = 0
        for line in lines:
            n += self.write(line)
        return n

    def read(self, size=-1):
        _check_blob(self)
        cdef:
            bytes pybuf
            int length
            int blob_size = sqlite3_blob_bytes(self.blob)
            int remaining = blob_size - self.offset

        if remaining <= 0:
            return b''

        # Clamp to the remaining bytes (also avoids overflowing the C int
        # when a very large size is requested).
        if size is None or size < 0 or size > remaining:
            length = remaining
        else:
            length = size

        if length == 0:
            return b''

        pybuf = _blob_read(self, length, self.offset)
        self.offset += length
        return pybuf

    def readall(self):
        return self.read()

    def readinto(self, b):
        _check_blob(self)
        cdef:
            Py_buffer view
            int remaining = sqlite3_blob_bytes(self.blob) - self.offset
            int n_read

        if remaining == 0:
            return 0

        PyObject_GetBuffer(b, &view, PyBUF_CONTIG)
        n_read = remaining if <int>view.len >= remaining else <int>view.len
        try:
            if sqlite3_blob_read(self.blob, view.buf, n_read, self.offset):
                self._close()
                raise_sqlite_error(self.conn, 'error reading from blob: ')
        finally:
            PyBuffer_Release(&view)

        self.offset += n_read
        return n_read

    def write(self, data):
        _check_blob(self)
        if self._read_only:
            raise _io.UnsupportedOperation('write')
        if data is None:
            raise TypeError('write() does not accept None')

        cdef:
            const void *buf = NULL
            int n, blob_size
            Py_buffer view
            Py_ssize_t buflen
            bint buffer_acquired = False

        if not data:
            return 0

        blob_size = sqlite3_blob_bytes(self.blob)

        if PyObject_CheckBuffer(data):
            PyObject_GetBuffer(data, &view, PyBUF_CONTIG_RO)
            buffer_acquired = True
            buf = view.buf
            buflen = view.len
        elif isinstance(data, str):
            buf = PyUnicode_AsUTF8AndSize(data, &buflen)
        else:
            raise TypeError('Blob.write() data must be buffer, bytes or str')

        try:
            if buflen > <Py_ssize_t>INT_MAX:
                raise ValueError('Data is too large')
            n = <int>buflen
            if n > 0 and (<int64_t>n + <int64_t>self.offset) > <int64_t>blob_size:
                raise ValueError('Data would go beyond end of blob.')

            if sqlite3_blob_write(self.blob, buf, n, self.offset):
                raise_sqlite_error(self.conn, 'error writing to blob: ')
        finally:
            if buffer_acquired:
                PyBuffer_Release(&view)

        self.offset += n
        return n

    def seek(self, offset, whence=0):
        _check_blob(self)
        cdef:
            int blob_size = sqlite3_blob_bytes(self.blob)
            int new_pos

        if whence == 0:
            new_pos = offset
        elif whence == 1:
            new_pos = self.offset + offset
        elif whence == 2:
            new_pos = blob_size + offset
        else:
            raise ValueError('seek() whence must be 0, 1 or 2.')

        if new_pos < 0 or new_pos > blob_size:
            raise ValueError('seek() offset outside of valid range.')

        self.offset = new_pos
        return self.offset

    def tell(self):
        _check_blob(self)
        return self.offset

    def __len__(self):
        _check_blob(self)
        return sqlite3_blob_bytes(self.blob)

    def __getitem__(self, key):
        _check_blob(self)
        cdef:
            int blob_size = sqlite3_blob_bytes(self.blob)
            int idx, start, stop, length
            bytes buf

        if isinstance(key, int):
            idx = key
            if idx < 0:
                idx += blob_size
            if idx < 0 or idx >= blob_size:
                raise IndexError('blob index out of range')

            buf = _blob_read(self, 1, idx)
            return <unsigned char>PyBytes_AS_STRING(buf)[0]

        if not isinstance(key, slice):
            raise TypeError('Blob.__getitem__ must be integer or slice')

        start, stop, step = key.indices(blob_size)
        if step != 1:
            raise ValueError('blob slice step value must be 1')

        length = stop - start
        if length <= 0:
            return b''

        return _blob_read(self, length, start)

    def __setitem__(self, key, value):
        _check_blob(self)
        if self._read_only:
            raise _io.UnsupportedOperation('write')

        cdef:
            int blob_size = sqlite3_blob_bytes(self.blob)
            int idx, start, stop, length
            unsigned char byte_val
            Py_buffer view

        if isinstance(key, int):
            idx = key
            if idx < 0:
                idx += blob_size
            if idx < 0 or idx >= blob_size:
                raise IndexError('blob index out of range')

            if isinstance(value, int):
                if not (0 <= value <= 255):
                    raise ValueError('byte must be in range(0, 256)')
                byte_val = <unsigned char>value
                if sqlite3_blob_write(self.blob, &byte_val, 1, idx):
                    raise_sqlite_error(self.conn, 'error writing to blob: ')
            else:
                PyObject_GetBuffer(value, &view, PyBUF_CONTIG_RO)
                try:
                    if view.len != 1:
                        raise ValueError(
                            'blob index assignment requires a single byte, '
                            'got %d bytes' % view.len)
                    if sqlite3_blob_write(self.blob, view.buf, 1, idx):
                        raise_sqlite_error(self.conn,
                                           'error writing to blob: ')
                finally:
                    PyBuffer_Release(&view)
            return

        if not isinstance(key, slice):
            raise TypeError('Blob.__setitem__ must be integer or slice')

        start, stop, step = key.indices(blob_size)
        if step != 1:
            raise ValueError('blob slice step value must be 1')

        length = stop - start
        PyObject_GetBuffer(value, &view, PyBUF_CONTIG_RO)
        try:
            if view.len != length:
                raise ValueError(
                    'blob slice of length %d cannot be assigned from a '
                    'buffer of length %d' % (length, view.len))
            if length > 0:
                if sqlite3_blob_write(self.blob, view.buf, length, start):
                    raise_sqlite_error(self.conn, 'error writing to blob: ')
        finally:
            PyBuffer_Release(&view)


# Support RawIOBase.
_io.RawIOBase.register(Blob)

# The cysqlite_vtab struct embeds the base sqlite3_vtab struct, and adds a
# field to store a reference to the Python implementation and a borrowed ptr to
# the parent Connection. The vtab holds its own reference on the
# TableFunction subclass (INCREF in cyConnect, DECREF in cyDisconnect); the
# conn ptr is only dereferenced from callbacks that run during statement
# execution, which requires a live Connection.
ctypedef struct cysqlite_vtab:
    sqlite3_vtab base
    void *table_func_cls
    void *conn


# Like cysqlite_vtab, the cysqlite_cursor embeds the base sqlite3_vtab_cursor
# and adds fields to store references to the current index, the Python
# implementation, the current rows' data, and a flag for whether the cursor has
# been exhausted.
ctypedef struct cysqlite_cursor:
    sqlite3_vtab_cursor base
    long long idx
    void *table_func
    void *row_data
    bint stopped


cdef void set_vtab_error(sqlite3_vtab *pVtab, const char *msg) noexcept:
    if pVtab.zErrMsg:
        sqlite3_free(pVtab.zErrMsg)
    pVtab.zErrMsg = sqlite3_mprintf('%s', msg)


cdef inline Connection _vtab_connection(cysqlite_vtab *pVtab):
    # Return the owning Conn from a vtab. Callers only run while a statement
    # is executing on the connection, so the borrowed ptr is either valid or
    # NULL.
    if pVtab == NULL or pVtab.conn == NULL:
        return None
    return <Connection>pVtab.conn


cdef inline void _vtab_capture_exc(sqlite3_vtab *pBase, Connection conn,
                                   object table_func_cls, object exc,
                                   bytes prefix) noexcept with gil:
    # Stash `exc` on the connection for propagation (__cause__), surface the
    # error via the vTab's zErrMsg and optionally print a trace. Used by
    # cyNext, cyFilter and cyUpdate so user exceptions don't get swallowed
    # behind a generic OperationalError.
    cdef bytes msg
    if conn is not None:
        conn._callback_error = exc
    if table_func_cls is not None and \
       getattr(table_func_cls, 'print_tracebacks', False):
        traceback.print_exc()
    try:
        msg = prefix + encode('%s: %s' % (type(exc), exc))
    except Exception:
        msg = prefix + b'(error formatting exception)'
    set_vtab_error(pBase, <const char *>msg)


# We define an xConnect function, but leave xCreate NULL so that the
# table-function can be called eponymously.
cdef int cyConnect(sqlite3 *db, void *pAux, int argc, const char *const*argv,
                   sqlite3_vtab **ppVtab, char **pzErr) noexcept with gil:
    cdef:
        int rc
        object table_func_cls
        cysqlite_vtab *pNew = <cysqlite_vtab *>0
        _TableFunctionImpl impl
        bytes schema
        bytes err

    if pAux == NULL:
        pzErr[0] = sqlite3_mprintf('Missing table function class')
        return SQLITE_ERROR

    impl = <_TableFunctionImpl>pAux
    table_func_cls = impl.table_function
    try:
        schema = encode('CREATE TABLE x(%s);' %
                        table_func_cls.get_table_columns_declaration())
    except Exception as exc:
        err = encode(f'Failed to get schema: {exc}')
        pzErr[0] = sqlite3_mprintf('%s', <const char *>err)
        return SQLITE_ERROR

    rc = sqlite3_declare_vtab(db, <const char *>schema)
    if rc != SQLITE_OK:
        err = encode('sqlite3_declare_vtab failed: %s' %
                     decode(sqlite3_errmsg(db)))
        pzErr[0] = sqlite3_mprintf('%s', <const char *>err)
        return rc

    pNew = <cysqlite_vtab *>sqlite3_malloc(sizeof(pNew[0]))
    if pNew == NULL:
        pzErr[0] = sqlite3_mprintf('out of memory allocating vtab')
        return SQLITE_NOMEM

    memset(<char *>pNew, 0, sizeof(pNew[0]))
    ppVtab[0] = &(pNew.base)

    pNew.table_func_cls = <void *>table_func_cls
    pNew.conn = <void *>impl.conn
    Py_INCREF(table_func_cls)

    return SQLITE_OK


cdef int cyDisconnect(sqlite3_vtab *pBase) noexcept with gil:
    cdef:
        cysqlite_vtab *pVtab = <cysqlite_vtab *>pBase
        object table_func_cls

    if pVtab == NULL:
        return SQLITE_OK

    if pVtab.table_func_cls != NULL:
        table_func_cls = <object>(pVtab.table_func_cls)
        Py_DECREF(table_func_cls)

    sqlite3_free(pVtab)
    return SQLITE_OK


# The xOpen method is used to initialize a cursor. In this method we
# instantiate the TableFunction class and zero out a new cursor for iteration.
cdef int cyOpen(sqlite3_vtab *pBase, sqlite3_vtab_cursor **ppCursor) noexcept with gil:
    cdef:
        cysqlite_vtab *pVtab = <cysqlite_vtab *>pBase
        cysqlite_cursor *pCur = <cysqlite_cursor *>0
        object table_func_cls
        object table_func

    if pVtab == NULL or pVtab.table_func_cls == NULL:
        return SQLITE_ERROR

    table_func_cls = <object>pVtab.table_func_cls

    pCur = <cysqlite_cursor *>sqlite3_malloc(sizeof(pCur[0]))
    if pCur == NULL:
        return SQLITE_NOMEM

    memset(<char *>pCur, 0, sizeof(pCur[0]))
    pCur.idx = 0
    pCur.row_data = NULL
    pCur.stopped = False

    try:
        table_func = table_func_cls()
    except Exception as exc:
        if table_func_cls.print_tracebacks:
            traceback.print_exc()
        set_vtab_error(pBase, encode(f'Table function init failed: {exc}'))
        sqlite3_free(pCur)
        return SQLITE_ERROR

    Py_INCREF(table_func)
    pCur.table_func = <void *>table_func
    ppCursor[0] = &(pCur.base)
    return SQLITE_OK


cdef int cyClose(sqlite3_vtab_cursor *pBase) noexcept with gil:
    cdef:
        cysqlite_cursor *pCur = <cysqlite_cursor *>pBase
        object table_func

    if pCur == NULL:
        return SQLITE_OK

    if pCur.row_data != NULL:
        Py_DECREF(<tuple>pCur.row_data)
        pCur.row_data = NULL

    if pCur.table_func != NULL:
        table_func = <object>pCur.table_func
        Py_DECREF(table_func)
        pCur.table_func = NULL

    sqlite3_free(pCur)
    return SQLITE_OK


# Iterate once, advancing the cursor's index and assigning the row data to the
# `row_data` field on the cysqlite_cursor struct.
cdef int _store_row(cysqlite_cursor *pCur, object table_func,
                    object raw) except -1:
    # Validate the shape of a row produced by iterate() and store it on the
    # cursor. Returns 1 on success, 0 if iteration stopped, and raises an exc
    # if there's a shape mismatch.
    # Valid rows can be (c0, c1, ...) OR
    # (rowid, (c0, c1, ...)) when subclass sets with_rowid=True.
    cdef:
        tuple row
        tuple tmp
        int ncols = table_func._ncols
        bint with_rowid = table_func.with_rowid

    if raw is None:
        pCur.stopped = True
        return 0

    if not isinstance(raw, tuple):
        raise TypeError(f'iterate() must return a tuple')

    tmp = <tuple>raw
    if with_rowid:
        if len(tmp) != 2 or not isinstance(tmp[1], tuple) or \
           len(<tuple>tmp[1]) != ncols:
            raise ValueError('iterate() must return (rowid, tuple of %s cols)'
                             % ncols)
        pCur.idx = tmp[0]
        row = <tuple>tmp[1]
    else:
        if len(tmp) != ncols:
            raise ValueError('iterate() must return (tuple of %s cols)'
                             % ncols)
        row = tmp
        pCur.idx += 1

    Py_INCREF(row)
    pCur.row_data = <void *>row
    pCur.stopped = False
    return 1


# Pull the next row from the table function and store it on the cursor. Shared
# by cyFilter (first row, after it resets idx) and cyNext.
cdef int _vtab_advance(cysqlite_cursor *pCur, cysqlite_vtab *pVtab,
                       Connection conn, object table_func) noexcept with gil:
    cdef object raw

    if pCur.row_data != NULL:
        Py_DECREF(<tuple>pCur.row_data)
        pCur.row_data = NULL

    # Every path below sets `stopped`, except a BaseException escaping this
    # noexcept function. Keep the reset so that case behaves as it always has.
    pCur.stopped = False

    try:
        raw = table_func.iterate(pCur.idx)
    except StopIteration:
        pCur.stopped = True
        return SQLITE_OK
    except Exception as exc:
        _vtab_capture_exc(<sqlite3_vtab *>pVtab, conn, type(table_func), exc,
                          b'iterate() raised: ')
        pCur.stopped = True
        return SQLITE_ERROR

    try:
        _store_row(pCur, table_func, raw)
    except Exception as exc:
        _vtab_capture_exc(<sqlite3_vtab *>pVtab, conn, type(table_func), exc,
                          b'iterate() returned invalid row: ')
        pCur.stopped = True
        return SQLITE_ERROR

    return SQLITE_OK


cdef int cyNext(sqlite3_vtab_cursor *pBase) noexcept with gil:
    cdef:
        cysqlite_cursor *pCur = <cysqlite_cursor *>pBase
        cysqlite_vtab *pVtab

    if pCur == NULL or pCur.table_func == NULL:
        return SQLITE_ERROR

    pVtab = <cysqlite_vtab *>pBase.pVtab
    return _vtab_advance(pCur, pVtab, _vtab_connection(pVtab),
                         <object>pCur.table_func)


# Return the requested column from the current row.
cdef int cyColumn(sqlite3_vtab_cursor *pBase, sqlite3_context *ctx,
                  int iCol) noexcept with gil:
    cdef:
        cysqlite_cursor *pCur = <cysqlite_cursor *>pBase
        cysqlite_vtab *pVtab
        Connection conn
        object table_func_cls
        tuple row_data

    if pCur == NULL:
        sqlite3_result_error(ctx, encode('invalid cursor'), -1)
        return SQLITE_ERROR

    # Special case: rowid column
    if iCol == -1:
        sqlite3_result_int64(ctx, <sqlite3_int64>pCur.idx)
        return SQLITE_OK

    if pCur.row_data == NULL:
        sqlite3_result_null(ctx)
        return SQLITE_OK

    row_data = <tuple>pCur.row_data
    if iCol < 0 or iCol >= len(row_data):
        sqlite3_result_error(ctx, encode('column index out of bounds'), -1)
        return SQLITE_ERROR

    try:
        return python_to_sqlite(ctx, row_data[iCol])
    except Exception as exc:
        pVtab = <cysqlite_vtab *>pBase.pVtab
        conn = _vtab_connection(pVtab)
        table_func_cls = <object>pVtab.table_func_cls \
            if pVtab != NULL and pVtab.table_func_cls != NULL else None
        _vtab_capture_exc(<sqlite3_vtab *>pVtab, conn, table_func_cls, exc,
                          b'error converting column value: ')
        return SQLITE_ERROR


cdef int cyRowid(sqlite3_vtab_cursor *pBase, sqlite3_int64 *pRowid) noexcept:
    cdef:
        cysqlite_cursor *pCur = <cysqlite_cursor *>pBase

    if pCur == NULL or pRowid == NULL:
        return SQLITE_ERROR

    pRowid[0] = <sqlite3_int64>pCur.idx
    return SQLITE_OK


# Return a boolean indicating whether the cursor has been consumed.
cdef int cyEof(sqlite3_vtab_cursor *pBase) noexcept:
    cdef cysqlite_cursor *pCur = <cysqlite_cursor *>pBase
    return 1 if (pCur == NULL or pCur.stopped) else 0


# The filter method is called on the first iteration. This method is where we
# get access to the parameters that the function was called with, and call the
# TableFunction's `initialize()` function.
cdef int cyFilter(sqlite3_vtab_cursor *pBase, int idxNum,
                  const char *idxStr, int argc, sqlite3_value **argv) noexcept with gil:
    cdef:
        cysqlite_cursor *pCur = <cysqlite_cursor *>pBase
        cysqlite_vtab *pVtab
        object table_func
        Connection conn
        dict query = {}
        int idx
        tuple py_values
        list params

    if pCur == NULL or pCur.table_func == NULL:
        return SQLITE_ERROR

    # SQLite reuses one cursor across multiple xFilter calls (e.g. a table
    # function on the inner side of a join / correlated subq). Reset the
    # iteration index so each filter pass restarts iterate() from row 0 rather
    # than from the stale count left by the previous pass.
    pCur.idx = 0

    pVtab = <cysqlite_vtab *>pBase.pVtab
    conn = _vtab_connection(pVtab)
    table_func = <object>pCur.table_func

    if idxStr == NULL and table_func._nparams:
        return SQLITE_ERROR
    elif idxStr != NULL and len(idxStr):
        params = decode(idxStr).split(',')
    else:
        params = []

    try:
        py_values = sqlite_to_python(argc, argv)
    except Exception as exc:
        _vtab_capture_exc(<sqlite3_vtab *>pVtab, conn, type(table_func), exc,
                          b'error converting parameters: ')
        return SQLITE_ERROR

    for idx, param in enumerate(params):
        if idx < argc:
            query[param] = py_values[idx]
        else:
            query[param] = None

    try:
        table_func.initialize(**query)
    except Exception as exc:
        _vtab_capture_exc(<sqlite3_vtab *>pVtab, conn, type(table_func), exc,
                          b'initialize() raised: ')
        return SQLITE_ERROR

    # Get first row of data.
    return _vtab_advance(pCur, pVtab, conn, table_func)


# SQLite will (in some cases, repeatedly) call the xBestIndex method to try and
# find the best query plan.
cdef int cyBestIndex(sqlite3_vtab *pBase, sqlite3_index_info *pIdxInfo) \
        noexcept with gil:
    cdef:
        int i
        int nArg = 0
        cysqlite_vtab *pVtab = <cysqlite_vtab *>pBase
        object table_func_cls
        sqlite3_index_constraint *pConstraint = <sqlite3_index_constraint *>0
        list columns = []
        char *idxStr
        int nParams
        bytes joinedCols
        object required

    if pVtab == NULL or pVtab.table_func_cls == NULL:
        return SQLITE_ERROR

    table_func_cls = <object>pVtab.table_func_cls
    nParams = table_func_cls._nparams

    for i in range(pIdxInfo.nConstraint):
        pConstraint = <sqlite3_index_constraint *>pIdxInfo.aConstraint + i
        if not pConstraint.usable:
            continue
        if pConstraint.op != SQLITE_INDEX_CONSTRAINT_EQ:
            continue

        col_idx = pConstraint.iColumn - table_func_cls._ncols
        if col_idx < 0 or col_idx >= nParams:
            continue

        columns.append(table_func_cls.params[col_idx])
        nArg += 1
        pIdxInfo.aConstraintUsage[i].argvIndex = nArg
        pIdxInfo.aConstraintUsage[i].omit = 1

    # Decide whether this plan can satisfy the table function's required
    # params. Legacy subclasses (_required_params is None) keep the "at least
    # one param bound" rule. Generated functions declare which params lack a
    # Python default; only those are required, so an all-defaulted function can
    # be called with no args at all.
    required = table_func_cls._required_params
    if required is None:
        if nArg == 0 and nParams != 0:
            return SQLITE_CONSTRAINT
    else:
        for rp in required:
            if rp not in columns:
                return SQLITE_CONSTRAINT

    if nArg == nParams:
        # All parameters are present, this is ideal.
        pIdxInfo.estimatedCost = <double>1
        pIdxInfo.estimatedRows = 10
    else:
        # Penalize the plan for each missing parameter. The cost must
        # stay huge (so better-constrained plans always win) but also
        # distinguishable per missing param -- subtracting from DBL_MAX
        # does not work, as DBL_MAX - k == DBL_MAX for small k.
        pIdxInfo.estimatedCost = 1e99 * <double>(nParams - nArg)
        pIdxInfo.estimatedRows = 10 * (nParams - nArg)

    # Store a reference to the columns in the index info structure.
    joinedCols = encode(','.join(columns))
    idxStr = <char *>sqlite3_malloc((len(joinedCols) + 1) * sizeof(char))
    if idxStr == NULL:
        return SQLITE_NOMEM

    memcpy(idxStr, <char *>joinedCols, len(joinedCols))
    idxStr[len(joinedCols)] = b'\x00'
    pIdxInfo.idxStr = idxStr
    pIdxInfo.needToFreeIdxStr = 1
    return SQLITE_OK


# Handle INSERT / UPDATE / DELETE operations.
cdef int cyUpdate(sqlite3_vtab *pBase, int argc, sqlite3_value **argv,
                  sqlite3_int64 *pRowid) noexcept with gil:
    # xUpdate:
    # argc == 1 -> DELETE, argv[0] = rowid.
    # argc > 1, argv[0] is SQLITE_NULL, INSERT, argv[1] is new rowid or NULL.
    # argc > 1, argv[0] is non-NULL, UPDATE, argv[0] is old rowid.
    cdef:
        cysqlite_vtab *pVtab = <cysqlite_vtab *>pBase
        object table_func_cls
        object table_func
        Connection conn
        tuple py_values

    if pVtab == NULL or pVtab.table_func_cls == NULL:
        set_vtab_error(pBase, b'Invalid vtab')
        return SQLITE_ERROR

    table_func_cls = <object>pVtab.table_func_cls
    conn = _vtab_connection(pVtab)

    try:
        py_values = sqlite_to_python(argc, argv)
        table_func = table_func_cls()

        # Determine operation type:
        if argc == 1:
            result = table_func.delete(py_values[0])
        elif py_values[0] is None:
            new_rowid_val = py_values[1] if len(py_values) > 1 else None
            column_values = py_values[2:] if len(py_values) > 2 else []

            result = table_func.insert(new_rowid_val, column_values)

            if pRowid != NULL and result is not None:
                pRowid[0] = <sqlite3_int64>result
        else:
            old_rowid = py_values[0]
            new_rowid_val = py_values[1] if len(py_values) > 1 else old_rowid
            column_values = py_values[2:] if len(py_values) > 2 else []

            result = table_func.update(old_rowid, new_rowid_val, column_values)
    except NotImplementedError:
        set_vtab_error(pBase, b'Operation not implemented')
        return SQLITE_READONLY
    except Exception as exc:
        _vtab_capture_exc(pBase, conn, table_func_cls, exc, b'update failed: ')
        return SQLITE_ERROR

    return SQLITE_OK


# All table functions share one static module definition: the function
# pointers are identical for every registration, and per-function state (the
# TableFunction subclass and owning connection) travels through the pAux
# pointer given to sqlite3_create_module_v2(). A C global also guarantees the
# struct outlives every registration that refers to it -- SQLite dereferences
# it as late as connection teardown (clearing eponymous vtabs). Members not
# assigned below (xCreate, xBegin, xRename, ...) stay NULL from static
# initialization; xCreate in particular must remain NULL so the function can
# be invoked eponymously.
cdef sqlite3_module _tablefunc_module
_tablefunc_module.iVersion = 0
_tablefunc_module.xConnect = cyConnect
_tablefunc_module.xBestIndex = cyBestIndex
_tablefunc_module.xDisconnect = cyDisconnect
_tablefunc_module.xOpen = cyOpen
_tablefunc_module.xClose = cyClose
_tablefunc_module.xFilter = cyFilter
_tablefunc_module.xNext = cyNext
_tablefunc_module.xEof = cyEof
_tablefunc_module.xColumn = cyColumn
_tablefunc_module.xRowid = cyRowid
_tablefunc_module.xUpdate = cyUpdate


cdef class _TableFunctionImpl(object):
    cdef:
        object table_function
        Connection conn
        unicode name  # Resolved during class-construction.

    def __cinit__(self, table_function, Connection conn):
        self.table_function = table_function
        self.conn = conn
        self.name = table_function.name or table_function.__name__

    cdef create_module(self, Connection conn):
        check_connection(conn)

        cdef:
            bytes name = encode(self.name)
            int rc

        # No destructor: the impl is owned by the connection's `callbacks`
        # dict (see _Callback) and outlives the module registration that
        # borrows it.
        rc = sqlite3_create_module_v2(
            conn.db,
            <const char *>name,
            &_tablefunc_module,
            <void *>self,
            NULL)
        if rc != SQLITE_OK:
            raise_sqlite_error(
                conn,
                'failed to register table function %s: ' % self.name)

        return True


class TableFunction(object):
    """
    Base class for SQLite virtual table functions.

    Required:
    - columns: list of column names or (name, type) tuples
    - initialize(**filters): called once per query with parameter values
    - iterate(idx): yields row tuples, raise StopIteration when done

    Optional:
    - params: list of parameter names (optional, for table-valued functions),
        each becomes a hidden SQL column that can be supplied as a positional
        argument in the FROM clause, e.g. FROM my_tbl('p1', 'p2').
    - name: table name

    Optional methods for writable tables:
    - insert(rowid, values): handle INSERT, return rowid.
    - update(old_rowid, new_rowid, values): handle UPDATE, return None.
    - delete(rowid): handle DELETE, return None.
    """
    columns = None
    params = None
    name = None
    with_rowid = False
    print_tracebacks = False
    _ncols = 0
    _nparams = 0
    _required_params = None

    @classmethod
    def register(cls, Connection conn):
        if cls.columns is None:
            raise ProgrammingError(f'{cls.__name__}.columns must be defined')

        # Stored in conn.registrations so it is replayed on reconnect.
        conn._register_table_function(cls)

    @classmethod
    def from_function(cls, fn, name=None, columns=None, params=None):
        """
        Build a subclass of ``cls`` from a plain callable, without
        registering it on a connection. Connection.create_table_function()
        is this plus register(). Use this directly to register the same
        function on more than one connection.
        """
        name = name or getattr(fn, '__name__', None)
        if not name:
            raise ProgrammingError('table function requires a name')
        if columns is None:
            columns = getattr(fn, 'columns', None)
        if columns is None:
            raise ProgrammingError(
                f'{name}: columns must be passed or set on fn.columns')

        # Signature params become hidden SQL columns (in declaration order).
        # A param without a default is required. A param with a default is
        # optional. *args / **kwargs / positional-only params are not exposed
        # as params.
        sig_params, required = [], []
        for p in inspect.signature(fn).parameters.values():
            if p.kind in (p.POSITIONAL_OR_KEYWORD, p.KEYWORD_ONLY):
                sig_params.append(p.name)
                if p.default is inspect.Parameter.empty:
                    required.append(p.name)
        if params is None:
            params = sig_params
            req = frozenset(required)
        else:
            req = frozenset(p for p in required if p in params)

        def initialize(self, **filters):
            self._iter = iter(fn(**filters))    # defaults fill unbound params

        def iterate(self, idx):
            row = next(self._iter)              # StopIteration -> end of table
            return tuple(row) if type(row) is list else row

        return type(str(name), (cls,), {
            'columns': list(columns),
            'params': list(params),
            'name': name,
            '_required_params': req,
            'initialize': initialize,
            'iterate': iterate,
        })

    def __init_subclass__(cls, **kwargs):
        super().__init_subclass__(**kwargs)
        if cls.columns is not None:
            if not isinstance(cls.columns, (list, tuple)):
                raise ProgrammingError(
                    f'{cls.__name__}.columns must be a list or tuple')
            for col in cls.columns:
                if isinstance(col, str):
                    continue
                if isinstance(col, tuple) and len(col) == 2 \
                        and all(isinstance(p, str) for p in col):
                    continue
                raise ProgrammingError(
                    f'{cls.__name__}.columns entries must be strings or '
                    f'(name, type) 2-tuples of strings, got {col!r}')
        if cls.params is not None and not isinstance(cls.params, (list, tuple)):
            raise ProgrammingError(
                f'{cls.__name__}.params must be a list or tuple')
        cls._ncols = len(cls.columns) if cls.columns is not None else 0
        cls._nparams = len(cls.params) if cls.params is not None else 0

    def initialize(self, **filters):
        """
        Set up iteration state for one query.

        Called once per query after the SQL parameters are bound. The
        ``filters`` keyword arguments correspond to the names declared in
        ``params``. Parameters not constrained by the query are omitted, so
        declare a default for each, e.g. ``def initialize(self, n=None)``.
        """
        raise NotImplementedError

    def iterate(self, idx):
        """
        Return one row tuple of length ``len(columns)``.

        Called once per row, ``idx`` is the current 0-based row index. Raise
        ``StopIteration`` to indicate no more data.

        If the subclass sets ``with_rowid = True``, this method must return
        a 2-tuple of ``(rowid, row_tuple)`` instead.
        """
        raise NotImplementedError

    def insert(self, rowid, values):
        """
        Handle INSERT operation.

        ``rowid`` is the requested rowid (or None for auto-generate). Return
        the new row's ``rowid``.
        """
        raise NotImplementedError("INSERT not supported")

    def update(self, old_rowid, new_rowid, values):
        """
        Handle UPDATE operation.

        No return value.
        """
        raise NotImplementedError("UPDATE not supported")

    def delete(self, rowid):
        """
        Handle DELETE operation.

        No return value.
        """
        raise NotImplementedError("DELETE not supported")

    @classmethod
    def get_table_columns_declaration(cls):
        cdef list accum = []

        if cls.columns is None:
            raise ValueError("columns must be defined")

        for column in cls.columns:
            if isinstance(column, tuple):
                if len(column) != 2:
                    raise ValueError('Column must be either a string or a '
                                     '2-tuple of name, type')
                accum.append('%s %s' % column)
            else:
                accum.append(column)

        if cls.params:
            for param in cls.params:
                accum.append(f'{param} HIDDEN')

        return ', '.join(accum)


sqlite_version = decode(sqlite3_version)
sqlite_version_info = tuple(int(i) if i.isdigit() else i
                            for i in sqlite_version.split('.'))


def connect(database, flags=None, timeout=5.0, vfs=None, uri=False,
            cached_statements=100, extensions=True, row_factory=None,
            autoconnect=True, pragmas=None, journal_mode=None):
    """Open a connection to an SQLite database."""
    conn = Connection(database,
                      flags=flags,
                      timeout=timeout,
                      vfs=vfs,
                      uri=uri,
                      cached_statements=cached_statements,
                      extensions=extensions,
                      row_factory=row_factory,
                      autoconnect=autoconnect,
                      pragmas=pragmas,
                      journal_mode=journal_mode)
    return conn


def status(flag):
    cdef int current, highwater, rc

    rc = sqlite3_status(flag, &current, &highwater, 0)
    if rc != SQLITE_OK:
        raise OperationalError(f'error requesting status: {rc}')
    return (current, highwater)


def set_singlethread():
    return sqlite3_config(SQLITE_CONFIG_SINGLETHREAD) == SQLITE_OK
def set_multithread():
    return sqlite3_config(SQLITE_CONFIG_MULTITHREAD) == SQLITE_OK
def set_serialized():
    return sqlite3_config(SQLITE_CONFIG_SERIALIZED) == SQLITE_OK
def set_lookaside(int size, int slots):
    return sqlite3_config(SQLITE_CONFIG_LOOKASIDE, size, slots) == SQLITE_OK
def set_mmap_size(default_size, max_size):
    return sqlite3_config(SQLITE_CONFIG_MMAP_SIZE,
                          <sqlite3_int64>default_size,
                          <sqlite3_int64>max_size) == SQLITE_OK
def set_stmt_journal_spill(int nbytes):
    # nbytes is the spill-to-disk threshold. Statement journals are held in
    # memory until their size exceeds this threshold. Set to -1 to keep
    # journals exclusively in memory.
    return sqlite3_config(SQLITE_CONFIG_STMTJRNL_SPILL, nbytes) == SQLITE_OK


def compile_option(opt):
    cdef bopt = encode(opt)
    return sqlite3_compileoption_used(bopt)


HAS_COLUMN_METADATA = compile_option('enable_column_metadata')
HAS_LOAD_EXTENSION = bool(CYSQLITE_HAVE_LOAD_EXTENSION)
HAS_DESERIALIZE = bool(CYSQLITE_HAVE_DESERIALIZE)
#HAS_PREUPDATE_HOOK = compile_option('enable_preupdate_hook')
#HAS_STMT_SCANSTATUS = compile_option('enable_stmt_scanstatus')


def complete_statement(str sql):
    cdef bytes bsql = encode(sql)
    return bool(sqlite3_complete(bsql))


def vfs_list():
    cdef:
        sqlite3_vfs *vfs = sqlite3_vfs_find(NULL)
        list accum = []

    while vfs:
        name = decode(vfs.zName)
        accum.append(name)
        vfs = vfs.pNext
    return accum


cdef tuple sqlite_to_python(int argc, sqlite3_value **params):
    cdef:
        int i, vtype
        tuple result = PyTuple_New(argc)
        object value

    for i in range(argc):
        vtype = sqlite3_value_type(params[i])
        if vtype == SQLITE_NULL:
            value = None
        elif vtype == SQLITE_INTEGER:
            value = PyLong_FromLongLong(sqlite3_value_int64(params[i]))
        elif vtype == SQLITE_FLOAT:
            value = PyFloat_FromDouble(sqlite3_value_double(params[i]))
        elif vtype == SQLITE_TEXT:
            value = PyUnicode_DecodeUTF8(
                <const char *>sqlite3_value_text(params[i]),
                <Py_ssize_t>sqlite3_value_bytes(params[i]), NULL)
        elif vtype == SQLITE_BLOB:
            value = PyBytes_FromStringAndSize(
                <const char *>sqlite3_value_blob(params[i]),
                <Py_ssize_t>sqlite3_value_bytes(params[i]))
        else:
            value = None

        Py_INCREF(value)
        PyTuple_SET_ITEM(result, i, value)

    return result


cdef python_to_sqlite(sqlite3_context *context, param):
    cdef:
        const char *buf
        Py_ssize_t nbytes
        Py_buffer view

    if param is None:
        sqlite3_result_null(context)
    elif isinstance(param, int):
        if param > ((1 << 63) - 1) or param < -(1 << 63):
            sqlite3_result_error(context, encode('integer out of range'), -1)
            return SQLITE_ERROR
        sqlite3_result_int64(context, <sqlite3_int64>param)
    elif isinstance(param, float):
        sqlite3_result_double(context, <double>param)
    elif isinstance(param, unicode):
        buf = PyUnicode_AsUTF8AndSize(param, &nbytes)
        sqlite3_result_text64(context, buf,
                              <sqlite3_uint64>nbytes,
                              SQLITE_TRANSIENT,
                              SQLITE_UTF8)
    elif PyObject_CheckBuffer(param):
        # bytes, bytearray, memoryview.
        PyObject_GetBuffer(param, &view, PyBUF_CONTIG_RO)
        sqlite3_result_blob64(context, view.buf,
                              <sqlite3_uint64>(view.len),
                              SQLITE_TRANSIENT)
        PyBuffer_Release(&view)
    elif hasattr(param, '__float__'):
        # Decimal, Fraction, e.g.
        sqlite3_result_double(context, float(param))
    else:
        if isinstance(param, datetime.datetime):
            param = param.isoformat(' ')
        elif isinstance(param, (datetime.date, datetime.time)):
            param = param.isoformat()
        elif isinstance(param, uuid.UUID):
            param = str(param)
        else:
            raise TypeError('cannot convert result of type %s to a SQLite '
                            'value' % type(param).__name__)
        buf = PyUnicode_AsUTF8AndSize(param, &nbytes)
        sqlite3_result_text64(context, buf,
                              <sqlite3_uint64>nbytes,
                              SQLITE_TRANSIENT,
                              SQLITE_UTF8)

    return SQLITE_OK


# Misc helpers and user-defined functions / aggregates.


cdef double *get_weights(int ncol, tuple raw_weights):
    cdef:
        int argc = len(raw_weights)
        int icol
        double *weights = <double *>PyMem_Malloc(sizeof(double) * ncol)

    if weights == NULL:
        return NULL

    for icol in range(ncol):
        if argc == 0:
            weights[icol] = 1.0
        elif icol < argc:
            weights[icol] = <double>raw_weights[icol]
        else:
            weights[icol] = 0.0
    return weights


def rank_lucene(py_match_info, *raw_weights):
    # Usage: rank_lucene(matchinfo(table, 'pcnalx'), 1)
    cdef:
        unsigned int *match_info
        bytes _match_info_buf = bytes(py_match_info)
        char *match_info_buf
        Py_ssize_t buf_size
        int nphrase, ncol
        double total_docs, term_frequency
        double doc_length, docs_with_term, avg_length
        double tf, fieldNorms
        double idf, weight, rhs, denom
        double *weights
        int P_O = 0, C_O = 1, N_O = 2, L_O, X_O
        int iphrase, icol, x
        double score = 0.0
        Py_ssize_t required_size

    PyBytes_AsStringAndSize(_match_info_buf, &match_info_buf, &buf_size)
    if buf_size < <Py_ssize_t>(sizeof(unsigned int) * 3):
        raise ValueError('match_info buffer too small')

    match_info = <unsigned int *>match_info_buf
    nphrase = match_info[P_O]
    ncol = match_info[C_O]
    total_docs = match_info[N_O]

    L_O = 3 + ncol
    X_O = L_O + ncol
    weights = get_weights(ncol, raw_weights)
    if weights == NULL:
        raise MemoryError

    required_size = <Py_ssize_t>((X_O + 3 * nphrase * ncol) *
                                 sizeof(unsigned int))
    if buf_size < required_size:
        PyMem_Free(weights)
        raise ValueError('matchinfo buffer size incorrect')

    for iphrase in range(nphrase):
        for icol in range(ncol):
            weight = weights[icol]
            if weight == 0:
                continue
            doc_length = match_info[L_O + icol]
            x = X_O + (3 * (icol + iphrase * ncol))
            term_frequency = match_info[x]  # f(qi)
            docs_with_term = match_info[x + 2] or 1. # n(qi)
            idf = log(total_docs / (docs_with_term + 1.))
            tf = sqrt(term_frequency)
            fieldNorms = 1.0 / sqrt(doc_length)
            score += (idf * tf * fieldNorms)

    PyMem_Free(weights)
    return -1 * score


def rank_bm25(py_match_info, *raw_weights):
    # Usage: rank_bm25(matchinfo(table, 'pcnalx'), 1)
    # where the second parameter is the index of the column.
    cdef:
        unsigned int *match_info
        bytes _match_info_buf = bytes(py_match_info)
        char *match_info_buf
        Py_ssize_t buf_size
        int nphrase, ncol
        double B = 0.75, K = 1.2
        double total_docs, term_frequency
        double doc_length, docs_with_term, avg_length
        double idf, weight, ratio, num, b_part, denom, pc_score
        double *weights
        int P_O = 0, C_O = 1, N_O = 2, A_O = 3, L_O, X_O
        int iphrase, icol, x
        double score = 0.0
        Py_ssize_t required_size

    PyBytes_AsStringAndSize(_match_info_buf, &match_info_buf, &buf_size)
    if buf_size < <Py_ssize_t>(sizeof(unsigned int) * 3):
        raise ValueError('match_info buffer too small')

    match_info = <unsigned int *>match_info_buf
    # PCNALX = matchinfo format.
    # P = 1 = phrase count within query.
    # C = 1 = searchable columns in table.
    # N = 1 = total rows in table.
    # A = c = for each column, avg number of tokens
    # L = c = for each column, length of current row (in tokens)
    # X = 3 * c * p = for each phrase and table column,
    # * phrase count within column for current row.
    # * phrase count within column for all rows.
    # * total rows for which column contains phrase.
    nphrase = match_info[P_O]  # n
    ncol = match_info[C_O]
    total_docs = match_info[N_O]  # N

    L_O = A_O + ncol
    X_O = L_O + ncol
    weights = get_weights(ncol, raw_weights)
    if weights == NULL:
        raise MemoryError

    required_size = <Py_ssize_t>((X_O + 3 * nphrase * ncol) *
                                 sizeof(unsigned int))
    if buf_size < required_size:
        PyMem_Free(weights)
        raise ValueError('matchinfo buffer size incorrect')

    for iphrase in range(nphrase):
        for icol in range(ncol):
            weight = weights[icol]
            if weight == 0:
                continue

            x = X_O + (3 * (icol + iphrase * ncol))
            term_frequency = match_info[x]  # f(qi, D)
            docs_with_term = match_info[x + 2]  # n(qi)

            # log( (N - n(qi) + 0.5) / (n(qi) + 0.5) )
            idf = log(
                    (total_docs - docs_with_term + 0.5) /
                    (docs_with_term + 0.5))
            if idf <= 0.0:
                idf = 1e-6

            doc_length = match_info[L_O + icol]  # |D|
            avg_length = match_info[A_O + icol]  # avgdl
            if avg_length == 0:
                avg_length = 1
            ratio = doc_length / avg_length

            num = term_frequency * (K + 1)
            b_part = 1 - B + (B * ratio)
            denom = term_frequency + (K * b_part)

            pc_score = idf * (num / denom)
            score += (pc_score * weight)

    PyMem_Free(weights)
    return -1 * score


def damerau_levenshtein_dist(s1, s2):
    cdef:
        int i, j, del_cost, add_cost, sub_cost
        int s1_len = len(s1), s2_len = len(s2)
        list one_ago, two_ago, current_row
        list zeroes = [0] * (s2_len + 1)

    current_row = list(range(1, s2_len + 2))
    current_row[-1] = 0
    one_ago = None

    for i in range(s1_len):
        two_ago = one_ago
        one_ago = current_row
        current_row = list(zeroes)
        current_row[-1] = i + 1
        for j in range(s2_len):
            del_cost = one_ago[j] + 1
            add_cost = current_row[j - 1] + 1
            sub_cost = one_ago[j - 1] + (s1[i] != s2[j])
            current_row[j] = min(del_cost, add_cost, sub_cost)

            # Handle transpositions.
            if (i > 0 and j > 0 and s1[i] == s2[j - 1]
                and s1[i-1] == s2[j] and s1[i] != s2[j]):
                current_row[j] = min(current_row[j], two_ago[j - 2] + 1)

    return current_row[s2_len - 1]


def levenshtein_dist(a, b):
    cdef:
        int add, delete, change
        int i, j
        int n = len(a), m = len(b)
        list current, previous
        list zeroes

    if n > m:
        a, b = b, a
        n, m = m, n

    zeroes = [0] * (m + 1)
    current = list(range(n + 1))

    for i in range(1, m + 1):
        previous = current
        current = list(zeroes)
        current[0] = i

        for j in range(1, n + 1):
            add = previous[j] + 1
            delete = current[j - 1] + 1
            change = previous[j - 1]
            if a[j - 1] != b[i - 1]:
                change +=1
            current[j] = min(add, delete, change)

    return current[n]


cdef class median(object):
    cdef list items

    def __init__(self):
        self.items = []

    def step(self, item):
        if item is not None:
            insort(self.items, item)

    def inverse(self, item):
        if item is None:
            return

        cdef int idx = bisect_left(self.items, item)
        if idx >= len(self.items) or self.items[idx] != item:
            raise ValueError(f'item {item} not found in median window')
        del self.items[idx]

    def finalize(self):
        cdef int n = len(self.items)
        cdef int mid = n >> 1
        if n == 0:
            return None
        elif n & 1:
            return self.items[mid]
        return (self.items[mid - 1] + self.items[mid]) / 2.

    def value(self):
        return self.finalize()


cdef int _aggressive_busy_handler(void *ptr, int n) noexcept nogil:
    # In concurrent environments, it often seems that if multiple queries are
    # kicked off at around the same time, they proceed in lock-step to check
    # for the availability of the lock. By introducing some "jitter" we can
    # ensure that this doesn't happen. Furthermore, this function makes more
    # attempts in the same time period than the default handler.
    cdef:
        sqlite3_int64 busyTimeout = <sqlite3_int64>ptr
        int current, total

    if n < 20:
        current = 25 - (rand() % 10)  # ~20ms
        total = n * 20
    elif n < 40:
        current = 50 - (rand() % 20)  # ~40ms
        total = 400 + ((n - 20) * 40)
    else:
        current = 120 - (rand() % 40)  # ~100ms
        total = 1200 + ((n - 40) * 100)  # Estimate the amount of time slept.

    if total + current > busyTimeout:
        current = busyTimeout - total
    if current > 0:
        sqlite3_sleep(current)
        return 1
    return 0
