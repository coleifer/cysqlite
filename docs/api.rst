.. _api:

:tocdepth: 3

API
===

cysqlite APIs roughly follow the standard lib ``sqlite3`` module.

Module
------

.. py:function:: connect(database, flags=None, timeout=5.0, vfs=None, \
       uri=False, cached_statements=100, extensions=True, \
       row_factory=None, autoconnect=True)

   Open a :py:class:`Connection` to the provided database.

   :param database: database filename or ``':memory:'`` for an in-memory database.
   :type database: str, ``pathlib.Path``
   :param int flags: ``sqlite_open`` flags, e.g. :py:attr:`C_SQLITE_OPEN_READONLY`.
       Multiple flags can be combined with bitwise-or ``|``. See :ref:`sqlite-connection-flags`.
   :param float timeout: seconds to retry acquiring write lock before raising
       a :py:class:`OperationalError` when table is locked.
   :param str vfs: VFS to use, optional.
   :param bool uri: Allow connecting using a URI.
   :param int cached_statements: Size of statement cache.
   :param bool extensions: Support run-time loadable extensions.
   :param row_factory: Factory implementation for constructing rows.
   :param bool autoconnect: Open connection when instantiated.
   :return: Connection to database.
   :rtype: :py:class:`Connection`

   Example:

   .. code-block:: python

      # Create a connection with a 1s timeout and use the cysqlite Row for
      # query result tuples.
      conn = Connection('app.db', timeout=1.0, row_factory=Row)

.. py:function:: status(flag)

   Read the current and highwater values for the given status flag.

   :param int flag: status values to read.
   :return: (current, highwater)
   :rtype: tuple

Connection
----------

.. py:class:: Connection(database, flags=None, timeout=5.0, vfs=None, \
        uri=False, cached_statements=100, extensions=True, \
        row_factory=None, autoconnect=True)

   Open a :py:class:`Connection` to the provided database.

   :param database: database filename or ``':memory:'`` for an in-memory database.
   :type database: str, ``pathlib.Path``
   :param int flags: ``sqlite_open`` flags, e.g. :py:attr:`C_SQLITE_OPEN_READONLY`.
       Multiple flags can be combined with bitwise-or ``|``. See :ref:`sqlite-connection-flags`.
   :param float timeout: seconds to retry acquiring write lock before giving up.
   :param str vfs: VFS to use, optional.
   :param bool uri: Allow connecting using a URI.
   :param int cached_statements: Size of statement cache.
   :param bool extensions: Support run-time loadable extensions.
   :param row_factory: Factory implementation for constructing rows.
   :param bool autoconnect: Open connection when instantiated.

   .. py:method:: status(flag)

      Read the current and highwater values for the given db status flag.

      :param int flag: status values to read.
      :return: (current, highwater)
      :rtype: tuple

      .. seealso:: :ref:`sqlite-status-flags`

   .. py:method:: authorizer(fn)

      :param fn: authorizer callback
      :return: one of :py:attr:`C_SQLITE_OK`, :py:attr:`C_SQLITE_IGNORE` or
          :py:attr:`C_SQLITE_DENY`.

      .. seealso:: :ref:`authorizer-flags`

Constants
---------

.. py:attribute:: C_SQLITE_OK
    :type: int
    :value: 0

    General success response code used by SQLite.

Error codes
^^^^^^^^^^^

.. py:attribute:: C_SQLITE_ERROR
.. py:attribute:: C_SQLITE_INTERNAL
.. py:attribute:: C_SQLITE_PERM
.. py:attribute:: C_SQLITE_ABORT
.. py:attribute:: C_SQLITE_BUSY
.. py:attribute:: C_SQLITE_LOCKED
.. py:attribute:: C_SQLITE_NOMEM
.. py:attribute:: C_SQLITE_READONLY
.. py:attribute:: C_SQLITE_INTERRUPT
.. py:attribute:: C_SQLITE_IOERR
.. py:attribute:: C_SQLITE_CORRUPT
.. py:attribute:: C_SQLITE_NOTFOUND
.. py:attribute:: C_SQLITE_FULL
.. py:attribute:: C_SQLITE_CANTOPEN
.. py:attribute:: C_SQLITE_PROTOCOL
.. py:attribute:: C_SQLITE_EMPTY
.. py:attribute:: C_SQLITE_SCHEMA
.. py:attribute:: C_SQLITE_TOOBIG
.. py:attribute:: C_SQLITE_CONSTRAINT
.. py:attribute:: C_SQLITE_MISMATCH
.. py:attribute:: C_SQLITE_MISUSE
.. py:attribute:: C_SQLITE_NOLFS
.. py:attribute:: C_SQLITE_AUTH
.. py:attribute:: C_SQLITE_FORMAT
.. py:attribute:: C_SQLITE_RANGE
.. py:attribute:: C_SQLITE_NOTADB

.. _sqlite-status-flags:

Sqlite Status Flags
^^^^^^^^^^^^^^^^^^^

.. seealso::
   :py:func:`status`
      Read SQLite status, uses ``sqlite3_status`` internally.

.. py:attribute:: C_SQLITE_STATUS_MEMORY_USED
.. py:attribute:: C_SQLITE_STATUS_PAGECACHE_USED
.. py:attribute:: C_SQLITE_STATUS_PAGECACHE_OVERFLOW
.. py:attribute:: C_SQLITE_STATUS_SCRATCH_USED
.. py:attribute:: C_SQLITE_STATUS_SCRATCH_OVERFLOW
.. py:attribute:: C_SQLITE_STATUS_MALLOC_SIZE
.. py:attribute:: C_SQLITE_STATUS_PARSER_STACK
.. py:attribute:: C_SQLITE_STATUS_PAGECACHE_SIZE
.. py:attribute:: C_SQLITE_STATUS_SCRATCH_SIZE
.. py:attribute:: C_SQLITE_STATUS_MALLOC_COUNT

.. seealso::
   :py:meth:`Connection.status`
      Read SQLite database status, uses ``sqlite3_db_status`` internally.

.. py:attribute:: C_SQLITE_DBSTATUS_LOOKASIDE_USED
.. py:attribute:: C_SQLITE_DBSTATUS_CACHE_USED
.. py:attribute:: C_SQLITE_DBSTATUS_SCHEMA_USED
.. py:attribute:: C_SQLITE_DBSTATUS_STMT_USED
.. py:attribute:: C_SQLITE_DBSTATUS_LOOKASIDE_HIT
.. py:attribute:: C_SQLITE_DBSTATUS_LOOKASIDE_MISS_SIZE
.. py:attribute:: C_SQLITE_DBSTATUS_LOOKASIDE_MISS_FULL
.. py:attribute:: C_SQLITE_DBSTATUS_CACHE_HIT
.. py:attribute:: C_SQLITE_DBSTATUS_CACHE_MISS
.. py:attribute:: C_SQLITE_DBSTATUS_CACHE_WRITE
.. py:attribute:: C_SQLITE_DBSTATUS_DEFERRED_FKS

.. _sqlite-connection-flags:

Sqlite Connection Flags
^^^^^^^^^^^^^^^^^^^^^^^

.. seealso::
   :py:class:`Connection` and :py:func:`connect`
      Flags for controlling how connection is opened.

.. py:attribute:: C_SQLITE_OPEN_READONLY
.. py:attribute:: C_SQLITE_OPEN_READWRITE
.. py:attribute:: C_SQLITE_OPEN_CREATE
.. py:attribute:: C_SQLITE_OPEN_URI
.. py:attribute:: C_SQLITE_OPEN_MEMORY
.. py:attribute:: C_SQLITE_OPEN_NOMUTEX
.. py:attribute:: C_SQLITE_OPEN_FULLMUTEX
.. py:attribute:: C_SQLITE_OPEN_SHAREDCACHE
.. py:attribute:: C_SQLITE_OPEN_PRIVATECACHE

VFS-only Connection Flags
^^^^^^^^^^^^^^^^^^^^^^^^^

Support for these flags is dependent on the VFS providing an implementation.

.. py:attribute:: C_SQLITE_OPEN_DELETEONCLOSE
.. py:attribute:: C_SQLITE_OPEN_EXCLUSIVE
.. py:attribute:: C_SQLITE_OPEN_AUTOPROXY
.. py:attribute:: C_SQLITE_OPEN_WAL
.. py:attribute:: C_SQLITE_OPEN_MAIN_DB
.. py:attribute:: C_SQLITE_OPEN_TEMP_DB
.. py:attribute:: C_SQLITE_OPEN_TRANSIENT_DB
.. py:attribute:: C_SQLITE_OPEN_MAIN_JOURNAL
.. py:attribute:: C_SQLITE_OPEN_TEMP_JOURNAL
.. py:attribute:: C_SQLITE_OPEN_SUBJOURNAL
.. py:attribute:: C_SQLITE_OPEN_MASTER_JOURNAL

.. _authorizer-flags:

Authorizer Constants
^^^^^^^^^^^^^^^^^^^^

.. seealso::
   Setting an authorizer callback.
      :py:meth:`Connection.authorizer`

Return values (along with :py:attr:`C_SQLITE_OK`) for authorizer callback.

.. py:attribute:: C_SQLITE_DENY
.. py:attribute:: C_SQLITE_IGNORE

Operations reported to authorizer callback.

.. py:attribute:: C_SQLITE_CREATE_INDEX
.. py:attribute:: C_SQLITE_CREATE_TABLE
.. py:attribute:: C_SQLITE_CREATE_TEMP_INDEX
.. py:attribute:: C_SQLITE_CREATE_TEMP_TABLE
.. py:attribute:: C_SQLITE_CREATE_TEMP_TRIGGER
.. py:attribute:: C_SQLITE_CREATE_TEMP_VIEW
.. py:attribute:: C_SQLITE_CREATE_TRIGGER
.. py:attribute:: C_SQLITE_CREATE_VIEW
.. py:attribute:: C_SQLITE_DELETE
.. py:attribute:: C_SQLITE_DROP_INDEX
.. py:attribute:: C_SQLITE_DROP_TABLE
.. py:attribute:: C_SQLITE_DROP_TEMP_INDEX
.. py:attribute:: C_SQLITE_DROP_TEMP_TABLE
.. py:attribute:: C_SQLITE_DROP_TEMP_TRIGGER
.. py:attribute:: C_SQLITE_DROP_TEMP_VIEW
.. py:attribute:: C_SQLITE_DROP_TRIGGER
.. py:attribute:: C_SQLITE_DROP_VIEW
.. py:attribute:: C_SQLITE_INSERT
.. py:attribute:: C_SQLITE_PRAGMA
.. py:attribute:: C_SQLITE_READ
.. py:attribute:: C_SQLITE_SELECT
.. py:attribute:: C_SQLITE_TRANSACTION
.. py:attribute:: C_SQLITE_UPDATE
.. py:attribute:: C_SQLITE_ATTACH
.. py:attribute:: C_SQLITE_DETACH
.. py:attribute:: C_SQLITE_ALTER_TABLE
.. py:attribute:: C_SQLITE_REINDEX
.. py:attribute:: C_SQLITE_ANALYZE
.. py:attribute:: C_SQLITE_CREATE_VTABLE
.. py:attribute:: C_SQLITE_DROP_VTABLE
.. py:attribute:: C_SQLITE_FUNCTION
.. py:attribute:: C_SQLITE_SAVEPOINT
.. py:attribute:: C_SQLITE_COPY
.. py:attribute:: C_SQLITE_RECURSIVE
