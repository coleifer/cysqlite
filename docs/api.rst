.. _api:


API
===

cysqlite APIs roughly follow the standard lib ``sqlite3`` module.

Module
------

.. function:: connect(database, flags=None, timeout=5.0, vfs=None, \
       uri=False, cached_statements=100, extensions=True, \
       row_factory=None, autoconnect=True)

   Open a :class:`Connection` to the provided database.

   :param database: database filename or ``':memory:'`` for an in-memory database.
   :type database: str, ``pathlib.Path``
   :param int flags: control how database is opened. See :ref:`sqlite-connection-flags`.
   :param float timeout: seconds to retry acquiring write lock before raising
       a :class:`OperationalError` when table is locked.
   :param str vfs: VFS to use, optional.
   :param bool uri: Allow connecting using a URI.
   :param int cached_statements: Size of statement cache.
   :param bool extensions: Support run-time loadable extensions.
   :param row_factory: Factory implementation for constructing rows, e.g. :class:`Row`
   :param bool autoconnect: Open connection when instantiated.
   :return: Connection to database.
   :rtype: :class:`Connection`

   Default flags are ``SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE``. If ``uri``
   is set **or** ``'://'`` occurs in the database name, ``SQLITE_OPEN_URI``
   will be included.

   Example:

   .. code-block:: python

      # Create a connection with a 1s timeout and use the cysqlite Row for
      # query result tuples.
      conn = Connection('app.db', timeout=1.0, row_factory=Row)

.. function:: status(flag)

   Read the current and highwater values for the given status flag.

   :param int flag: status values to read.
   :return: (current, highwater)
   :rtype: tuple

.. data:: sqlite_version

   Version number of the runtime SQLite library as a string.

.. data:: sqlite_version_info

   Version number of the runtime SQLite library as a tuple of integers.

.. data:: threadsafety

   Integer constant required by the DB-API 2.0, stating the level of thread
   safety the cysqlite module supports. This attribute is set based on the
   default threading mode the underlying SQLite library is compiled with.
   The SQLite threading modes are:

   1. **Single-thread**: In this mode, all mutexes are disabled and SQLite is
      unsafe to use in more than a single thread at once.
   2. **Multi-thread**: In this mode, SQLite can be safely used by multiple threads
      provided that no single database connection is used simultaneously in two
      or more threads.
   3. **Serialized**: In serialized mode, SQLite can be safely used by multiple
      threads with no restriction.

   The value of this constant is determined by ``sqlite3_threadsafe()``, and
   will return one of three values:

   * 0 = SQLite is not thread-safe.
   * 1 = The module may be used in a multi-threaded application, but
     Connections cannot be shared by threads.
   * 3 = Connections may be shared by threads, no restrictions.


Connection
----------

.. class:: Connection(database, flags=None, timeout=5.0, vfs=None, \
        uri=False, cached_statements=100, extensions=True, \
        row_factory=None, autoconnect=True)

   Open a :class:`Connection` to the provided database.

   :param database: database filename or ``':memory:'`` for an in-memory database.
   :type database: str, ``pathlib.Path``
   :param int flags: control how database is opened. See :ref:`sqlite-connection-flags`.
   :param float timeout: seconds to retry acquiring write lock before giving up.
   :param str vfs: VFS to use, optional.
   :param bool uri: Allow connecting using a URI.
   :param int cached_statements: Size of statement cache.
   :param bool extensions: Support run-time loadable extensions.
   :param row_factory: Factory implementation for constructing rows, e.g. :class:`Row`
   :param bool autoconnect: Open connection when instantiated.

   Default flags are ``SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE``. If ``uri``
   is set **or** ``'://'`` occurs in the database name, ``SQLITE_OPEN_URI``
   will be included.

   Examples:

   .. code-block:: python

      # Simple connection
      conn = cysqlite.Connection('app.db')

      # In-memory database
      conn = cysqlite.Connection(':memory:')

      # Read-only connection
      conn = cysqlite.Connection('data.db',
                                 flags=cysqlite.SQLITE_OPEN_READONLY)

      # Custom row factory
      conn = cysqlite.Connection('app.db', row_factory=cysqlite.Row)

   .. attribute:: row_factory

      Factory for creating row instances from query results, e.g. :class:`Row`.
      By default rows are returned as ``tuple`` instances.

   .. attribute:: print_callback_tracebacks

      Print tracebacks for exceptions raised in user-defined callbacks. Since
      these callbacks are executed by SQLite, exceptions may not propagate in
      cases where the SQLite callback specifies no return code (e.g. rollback
      hooks).

   .. property:: callback_error

      Return the most-recent error raised inside a user-defined callback. Upon
      reading (or when the database is closed) this value is cleared.

   .. method:: register_converter(data_type, fn)

      Register a converter for non-standard data-types declared in SQLite, e.g.
      ``DATETIME`` or ``NUMERIC(x, y)``. SQLite can only natively store a
      handful of data-types (see :ref:`sqlite-notes` for details).

      The ``fn`` function accepts a single value and converts it. ``fn(value)``
      will **not** be called if the value is ``None``, so you do not need to
      test for ``value is None`` in your converter functions.

      :param str data_type: declared SQLite data-type to apply conversion to.
      :param fn: ``callable`` that accepts a single value and converts it.

      .. seealso:: :meth:`Connection.converter` decorator.

      Example:

      .. code-block:: python

         db = cysqlite.connect(':memory:')

         # Automatically parse and load data declared as JSON.
         db.register_converter('json', json.loads)

         # Or use the `converter()` decorator.
         @db.converter('datetime')
         def convert_datetime(value):
             # Converts our ISO-formatted date string into a python datetime.
             return datetime.datetime.fromisoformat(value)

         # Handle decimal data.
         @db.converter('numeric')
         def convert_numeric(value):
             return Decimal(value).quantize(Decimal('1.00'))

         db.execute('create table vals (ts datetime, js json, dec numeric(10, 2))')

         # Create a TZ-aware datetime, a JSON object and a Decimal.
         ts = datetime.datetime(2026, 1, 2, 3, 4, 5).astimezone(datetime.timezone.utc)
         js = {'key': {'nested': 'value'}, 'arr': ['i0', 1, 2., None]}
         dec = Decimal('1.3')

         # When we INSERT the JSON, note that we need to dump it to string.
         db.execute('insert into vals (ts, js, dec) values (?, ?, ?)',
                    (ts, json.dumps(js), dec))

         # When reading back the data, it is converted automatically based on
         # the declared column types.
         row = db.execute_one('select * from vals')
         assert row == (ts, js, dec)

      The converter ``data_type`` uses the following rules for matching what
      SQLite tells us:

      * Matching is case-insensitive, e.g. ``JSON`` or ``json`` is fine.
      * If a registered data-type is a complete match, use it.
      * Otherwise split on the first whitespace or ``"("`` character and look for
        that, e.g. ``NUMERIC(10, 2)`` will match our registered ``numeric``
        converter.

      .. seealso::  :ref:`sqlite-notes` for more information on SQLite data-types.

   .. method:: converter(data_type)

      Decorator for registering user-defined converters.

      :param str data_type: declared SQLite data-type to apply conversion to.

      .. code-block:: python

         db = cysqlite.connect(':memory:')

         @db.converter('datetime')
         def convert_datetime(value):
             # Converts our ISO-formatted date string into a python datetime.
             return datetime.datetime.fromisoformat(value)

      .. seealso:: :meth:`Connection.register_converter`

   .. method:: unregister_converter(data_type)

      Unregister converter for the given data type.

      :param str data_type: declared SQLite data-type to apply conversion to.
      :return: True or False if data-type was found and removed.

   .. method:: connect()

      Open connection to the database.

      :return: ``True`` if database was previously closed and is now open. If
          database was already open returns ``False``.
      :rtype: bool
      :raises: :class:`OperationalError` if opening database fails.

   .. method:: close()

      Close the database, finalizing all cursors and other hooks and handles
      associated with the active connection.

      :return: ``True`` if database was previously open and is now closed. If
          database was already closed returns ``False``.
      :rtype: bool
      :raises: :class:`OperationalError` if transaction is still active or
          an error occurs while closing the connection.

   .. method:: is_closed()

      :return: whether database is currently closed.
      :rtype: bool

   .. method:: cursor()

      Create a reusable cursor for executing queries.

      :return: a cursor for executing queries.
      :rtype: :class:`Cursor`

      .. seealso:: :class:`Cursor`

      .. note::
          The use of :meth:`~Connection.cursor` is optional. There is no
          performance difference between creating a cursor and calling
          :meth:`Cursor.execute` versus calling :meth:`Connection.execute`,
          as the latter will create and return a :class:`Cursor`.

   .. method:: execute(sql, params=None)

      Create a new :class:`Cursor` and call :meth:`~Cursor.execute` with the
      given *sql* and *params*.

      :param str sql: SQL query to execute.
      :param params: parameters for query (optional).
      :type params: tuple, list, sequence, dict, or ``None``.
      :return: cursor object.
      :rtype: :class:`Cursor`

      Example:

      .. code-block:: python

         db.execute('create table kv ("id" integer primary key, "key", "value")')

         # Iterate over results from a bulk-insert.
         curs = db.execute('insert into kv (key, value) values (?, ?), (?, ?) '
                           'returning id, key', ('k1', 'v1', 'k2', 'v2'))
         for (i, k) in curs:
             print(f'inserted {k} with id={i}')

         # Retrieve a single row result. Use a named parameter.
         curs = db.execute('select * from kv where id = :pk', {'pk': 1})
         row = curs.fetchone()
         print(f'retrieved row 1: {row}')

         # Empty result set.
         curs = db.execute('select * from kv where id = 0')
         assert curs.fetchone() is None
         assert curs.fetchall() == []

   .. method:: executemany(sql, seq_of_params)

      Create a new :class:`Cursor` and call :meth:`~Cursor.executemany` with
      with given *sql* and *seq_of_params*.

      Queries executed by :meth:`~Connection.executemany` must not return any
      result rows, or this will result in an :class:`OperationalError`.

      :param str sql: SQL query to execute.
      :param seq_of_params: iterable of parameters to repeatedly execute the
        query with.
      :type seq_of_params: sequence of: tuple, list, sequence, or dict.
      :return: cursor object.
      :rtype: :class:`Cursor`

      Example:

      .. code-block:: python

         db.execute('create table kv ("id" integer primary key, "key", "value")')

         curs = db.executemany('insert into kv (key, value) values (?, ?)',
                               [('k1', 'v1'), ('k2', 'v2'), ('k3', 'v3')])
         print(curs.lastrowid)  # 3.
         print(curs.rowcount)  # 3.

         curs = db.executemany('insert into kv (key, value) values (:k, :v)',
                               [{'k': 'k4', 'v': 'v4'}, {'k': 'k5', 'v': 'v5'}])
         print(curs.lastrowid)  # 5.
         print(curs.rowcount)  # 2.

   .. method:: executescript(sql)

      Execute the SQL statement(s) in *sql*.

      :param str sql: One or more SQL statements to execute in a script.
      :return: cursor object.
      :rtype: :class:`Cursor`

      Example:

      .. code-block:: python

         db.executescript("""
             begin;
             create table users (
                id integer not null primary key,
                name text not null,
                email text not null);
             create indexusers_email ON users (email);

             create table tweets (
                id integer not null primary key,
                content text not null,
                user_id integer not null references users (id),
                timestamp integer not null);

             commit;
         """)

   .. method:: execute_one(sql, params=None)

      Create a new :class:`Cursor` and call :meth:`~Cursor.execute` with the
      given *sql* and *params*. Returns the first result row, if one exists.

      :param str sql: SQL query to execute.
      :param params: parameters for query (optional).
      :type params: tuple, list, sequence, dict, or ``None``.
      :return: a single row of data or ``None`` if no results.

      Example:

      .. code-block:: python

         row = db.execute_one('select * from users where id = ?', (1,))

         row = db.execute_one('select * from users where name = :username',
                              {'username': 'charlie'})

   .. method:: execute_scalar(sql, params=None)

      Create a new :class:`Cursor` and call :meth:`~Cursor.execute` with the
      given *sql* and *params*. Returns the first value of the first result
      row, if one exists. Useful for aggregates or queries that only return a
      single value.

      :param str sql: SQL query to execute.
      :param params: parameters for query (optional).
      :type params: tuple, list, sequence, dict, or ``None``.
      :return: a single value or ``None`` if no result.

      .. code-block:: python

         count = db.execute_scalar('select count(*) from users')

   .. method:: begin(lock=None)

      Begin a transaction.

      If a transaction is already active, raises :class:`OperationalError`.

      :param str lock: type of SQLite lock to acquire, ``DEFERRED`` (default),
         ``IMMEDIATE``, or ``EXCLUSIVE``.

      .. note::
          SQLite does not support nesting transactions using BEGIN/COMMIT. To
          have nested transactions, SAVEPOINTs must be used within a
          transaction. SAVEPOINTs are safe to nest.

          To avoid having to do book-keeping, use :meth:`Connection.atomic` to
          decorate or wrap blocks which need to be executed atomically within a
          transactional context. The appropriate wrapper (transaction or
          savepoint) will automatically be used.

          See :meth:`Connection.atomic` for details.

      .. code-block:: python

         db = connect(':memory:')

         assert db.autocommit()  # Autocommit mode by default.

         db.begin()  # Now we are in a transaction.
         assert not db.autocommit()
         db.commit()

         assert db.autocommit()  # Back in autocommit mode.

   .. method:: commit()

      Commit the currently-active transaction.

      If no transaction is active, raises :class:`OperationalError`.

      .. seealso:: :meth:`Connection.atomic`

   .. method:: rollback()

      Roll-back the currently-active transaction.

      If no transaction is active, raises :class:`OperationalError`.

      .. seealso:: :meth:`Connection.atomic`

   .. method:: autocommit()

      Returns whether the database is in **autocommit** mode (no transaction is
      currently active).

      :rtype: bool

      .. code-block:: python

         db = connect(':memory:')

         # We are in autocommit-mode by default.
         assert db.autocommit()

         db.begin()
         assert not db.autocommit()  # We are in a transaction.
         db.commit()

         with db.atomic():
             assert not db.autocommit()  # In a transaction.

         assert db.autocommit()  # Back in autocommit mode.

   .. property:: in_transaction

      Returns whether a transaction is currently-active.

      :rtype: bool

   .. method:: atomic(lock=None)

      Create a context-manager which runs any queries in the wrapped block in
      a transaction (or savepoint when blocks are nested).

      Calls to :meth:`~Connection.atomic` can be nested.

      :meth:`~Connection.atomic` can also be used as a decorator.

      :param str lock: type of SQLite lock to acquire, ``DEFERRED`` (default),
         ``IMMEDIATE``, or ``EXCLUSIVE`` (only effective for outermost
         transaction).

      Example code:

      .. code-block:: python

         # All queries within the wrapped blocks are run inside a transaction
         # (or savepoint, when nested). When the block exits, the block will be
         # committed. If an unhandled exception occurs, the block will be
         # rolled back.
         with db.atomic() as txn:
             db.execute('...')

             with db.atomic() as nested_txn:
                 db.execute('...')

             # nested_txn is committed now.

         # Both blocks committed.

         @db.atomic
         def atomic_function():
             # All queries run inside a transaction (or savepoint) and commit
             # when the function returns, or roll-back if an exception occurs.
             db.execute('...')

      Transactions and save-points can be explicitly committed or rolled-back
      within the wrapped block. If this occurs, a new transaction or savepoint
      is begun immediately after the commit/rollback.

      Example:

      .. code-block:: python

         with db.atomic() as txn:
             db.execute('insert into users (username) values (?)', ('alice',))
             txn.commit()  # Changes are saved and a new transaction begins.

             db.execute('insert into users (username) values (?)', ('bob',))
             txn.rollback()  # "bob" will not be saved.

             with db.atomic() as nested:
                 db.execute('insert into users (username) values (?)', ('carl',))
                 nested.rollback()  # Rollback occurs, new savepoint begins.

                 db.execute('insert into users (username) values (?)', ('dale',))

         # Block has exited - transactions implicitly committed.

         # Print the usernames of all users.
         print(db.execute('select username from users').fetchall())

         # Prints [("alice",), ("dale",)]

   .. method:: transaction(lock=None)

      Create a context-manager that runs all queries in the wrapped block in
      a transaction.

      Calls to :meth:`~Connection.transaction` can be nested but **only the outer-most**
      transaction is used for implicit commits.

      :meth:`~Connection.transaction` can also be used as a decorator.

      :param str lock: type of SQLite lock to acquire, ``DEFERRED`` (default),
         ``IMMEDIATE``, or ``EXCLUSIVE``.

   .. method:: savepoint(sid=None)

      Create a context-manager that runs all queries in the wrapped block in
      a savepoint. Savepoints can only be used within an active transaction.

      Calls to :meth:`~Connection.savepoint` can be nested.

      :meth:`~Connection.savepoint` can also be used as a decorator.

      :param str sid: savepoint id (optional).

   .. method:: changes()

      Return the number of rows modified, inserted or deleted by the most
      recently completed INSERT, UPDATE or DELETE statement on the database
      connection.

      See `sqlite3_changes <https://www.sqlite.org/c3ref/changes.html>`_
      for details on what operations are counted.

      :rtype: int

   .. method:: total_changes()

      Return the total number of rows inserted, modified or deleted by **all**
      INSERT, UPDATE or DELETE statements completed since the database
      connection was opened, including those executed as part of triggers.

      See `sqlite3_total_changes <https://www.sqlite.org/c3ref/total_changes.html>`_
      for details on what operations are counted.

      :rtype: int

   .. method:: last_insert_rowid()

      Return the rowid of the most recent successful INSERT into a rowid table
      or virtual table on database connection. Inserts into WITHOUT ROWID
      tables are not recorded. If no successful INSERTs into rowid tables have
      ever occurred on the database connection, returns zero.

      See `sqlite3_last_insert_rowid <https://www.sqlite.org/c3ref/last_insert_rowid.html>`_
      for more details.

      :rtype: int

   .. method:: interrupt()

      Cause any pending database operation to abort and return at its earliest
      opportunity. This routine is typically called in response to a user
      action such as pressing "Cancel" or Ctrl-C where the user wants a long
      query operation to halt immediately.

   .. method:: status(flag)

      Read the current and highwater values for the given db status flag.

      :param int flag: status values to read.
      :return: (current, highwater)
      :rtype: tuple

      .. seealso:: :ref:`sqlite-status-flags`

      Example:

      .. code-block:: python

         db = connect('app.db')

         # Execute a query.
         db.execute('select * from register').fetchall()

         # Get the page cache used.
         print(db.status(SQLITE_STATUS_PAGECACHE_USED))
         # (123456, 0)

   .. method:: pragma(key, value=SENTINEL, database=None, multi=False)

      Read or write a SQLite `pragma <https://www.sqlite.org/pragma.html#toc>`_
      to check or adjust run-time behavior.

      :param str key: pragma name.
      :param value: value to use (when setting pragma).
      :param str database: database name to apply pragma to, *optional*.
      :param bool multi: when ``True``, return all results. Useful for pragmas
         that return multiple rows of data, e.g. ``table_list``.
      :return: the value of the specified pragma, or a :class:`Cursor` if ``multi``
         was specified.

      Example:

      .. code-block:: python

         db = connect('app.db')

         # Set database to WAL-mode, which allows multiple readers to co-exist
         # with a single writer.
         db.pragma('journal_mode', 'wal')

         # Log the cache size.
         cache_size = db.pragma('cache_size')
         if cache_size < 0:
             # Negative values are KiB.
             size_in_kb = abs(cache_size)
         else:
             # Positive values are in pages.
             size_in_kb = cache_size * db.pragma('page_size')

         print(f'Cache size: {size_in_kb}')

         # List all tables in the database.
         for row in db.pragma('table_list'):
             print(row[1])  # Print just the table name.

   .. method:: get_tables(database=None)

      List all tables in the database.

      :param str database: database name, *optional*.
      :return: ``list`` of table names.

   .. method:: get_views(database=None)

      List all VIEWs in the database.

      :param str database: database name, *optional*.
      :return: ``list`` of :class:`View` tuples.

      Example:

      .. code-block:: python

         print(db.get_views())
         [View(name='entries_public',
               sql='CREATE VIEW entries_public AS SELECT ... '),
          View(...),
          ...]

   .. method:: get_indexes(table, database=None)

      List all INDEXES on the table.

      :param str table: table name.
      :param str database: database name, *optional*.
      :return: ``list`` of :class:`Index` tuples.

      Example:

      .. code-block:: python

         print(db.get_indexes('entry'))
         [Index(
              name='entry_public_list',
              sql='CREATE INDEX "entry_public_list" ...',
              columns=['timestamp'],
              unique=False,
              table='entry'),
          Index(
              name='entry_slug',
              sql='CREATE UNIQUE INDEX "entry_slug" ON "entry" ("slug")',
              columns=['slug'],
              unique=True,
              table='entry')]

   .. method:: get_columns(table, database=None)

      List of columns in the table.

      :param str table: table name.
      :param str database: database name to query, *optional*.
      :return: ``list`` of :class:`Column` tuples.

      Example:

      .. code-block:: python

         print(db.get_columns('entry'))
         [Column(
              name='id',
              data_type='INTEGER',
              null=False,
              primary_key=True,
              table='entry'),
          Column(
              name='title',
              data_type='TEXT',
              null=False,
              primary_key=False,
              table='entry'),
          ...]

   .. method:: get_primary_keys(table, database=None)

      Return a list of column names that comprise the table primary key.

      :param str table: table name.
      :param str database: database name to query, *optional*.
      :return: ``list`` of key column names.

      Example:

      .. code-block:: python

         print(db.get_primary_keys('entry'))
         ['id']

   .. method:: get_foreign_keys(table, database=None)

      List of foreign-keys in the table.

      :param str table: table name.
      :param str database: database name to query, *optional*.
      :return: ``list`` of :class:`ForeignKey` tuples.

      Example:

      .. code-block:: python

         print(db.get_foreign_keys('entrytag'))
         [ForeignKeyMetadata(
              column='entry_id',
              dest_table='entry',
              dest_column='id',
              table='entrytag'),
          ...]

   .. method:: table_column_metadata(table, column, database=None)

      Provide full metadata for a column in a table.

      :param str table: table name.
      :param str column: column name.
      :param str database: database name to query, *optional*.
      :return: metadata for column.
      :rtype: :class:`ColumnMetadata`

      Example:

      .. code-block:: python

         db.table_column_metadata('entry', 'title')
         ColumnMetadata(
            table='entry',
            column='title',
            datatype='TEXT',
            collation='BINARY',
            not_null=True,
            primary_key=False,
            auto_increment=False)

   .. method:: backup(dest, pages=None, name=None, progress=None, src_name=None)

      Perform an online backup to the given destination :class:`Connection`.

      :param Connection destination: database to serve as destination for the backup.
      :param int pages: Number of pages per iteration. Default value of -1
          indicates all pages should be backed-up in a single step.
      :param str name: Name of source database (may differ if you used ATTACH
          DATABASE to load multiple databases). Defaults to "main".
      :param progress: Progress callback, called with three parameters: the
          number of pages remaining, the total page count, and whether the
          backup is complete.

      Example:

      .. code-block:: python

         master = connect('master.db')
         replica = connect('replica.db')

         # Backup the contents of master to replica.
         master.backup(replica)

      Progress example:

      .. code-block:: python

         master = connect('master.db')
         replica = connect('replica.db')

         def progress(remaining, total, is_complete):
             print(f'{remaining}/{total} pages remaining')

         # Backup the contents of master to replica.
         master.backup(replica, pages=10, progress=progress)

   .. method:: backup_to_file(filename, pages=None, name=None, progress=None, src_name=None)

      Perform an online backup to the given destination file.

      :param str filename: database file to serve as destination for the backup.
      :param int pages: Number of pages per iteration. Default value of -1
          indicates all pages should be backed-up in a single step.
      :param str name: Name of source database (may differ if you used ATTACH
          DATABASE to load multiple databases). Defaults to "main".
      :param progress: Progress callback, called with three parameters: the
          number of pages remaining, the total page count, and whether the
          backup is complete.

      Example:

      .. code-block:: python

         master = connect('master.db')

         # Backup the contents of master to replica.db.
         master.backup_to_file('replica.db')

   .. method:: blob_open(table, column, rowid, read_only=False, database=None)

      Open a :class:`Blob` handle to an existing :abbr:`BLOB (Binary Large OBject)`.

      :param str table: table where blob is stored.
      :param str column: column where blob is stored.
      :param int rowid: id of row to open.
      :param bool read_only: open blob in read-only mode.
      :param str database: database name, *optional*.
      :return: a handle to access the BLOB data.
      :rtype: :class:`Blob`

      .. note::

         The blob size cannot be changed using the :class:`Blob` class.
         Use the SQL function ``zeroblob`` to create a blob with a fixed size.

      .. seealso:: :class:`Blob`

      Example:

      .. code-block:: python

         db.execute('create table register ('
                    'id integer primary key, '
                    'data blob not null)')

         # Create a row with a 16-byte empty blob.
         db.execute('insert into register (data) values (zeroblob(?))', (16,))
         rowid = db.last_insert_rowid()

         # Obtain a handle to access the BLOB.
         blob = db.blob_open('register', 'data', rowid)

         blob.write(b'abcdefgh')
         assert blob.tell() == 8

         blob.seek(2)
         print(blob.read(4))  # b'cdef'

         blob.close()  # Release the blob handle.

   .. method:: load_extension(name)

      Load an extension module from a shared library.

      :param str name: the path to the SQLite extension.
      :raises: :class:`OperationalError` if extension could not be loaded.

      Example:

      .. code-block:: python

         # Create connection and indicate we want to support loadable
         # extensions.
         db = connect(':memory:', extensions=True)

         # Alternately, we can enable loadable extensions later.
         db.set_load_extension(True)

         # Load the closure table extension.
         db.load_extension('./closure.so')

   .. method:: create_function(fn, name=None, nargs=-1, deterministic=True)

      Create or remove a user-defined SQL function.

      :param fn:
          A callable that is called when the SQL function is invoked.
          The callable must return a type natively supported by SQLite. Set to
          ``None`` to remove an existing SQL function.
      :type func: callback | None
      :param str name: name of the SQL function. If unspecified, the name of
          the Python function will be used.
      :param int narg:
          The number of arguments the SQL function can accept. If ``-1``, it
          may take any number of arguments.
      :param bool deterministic:
          If ``True``, the created SQL function is marked as
          `deterministic <https://sqlite.org/deterministic.html>`_,
          which allows SQLite to perform additional optimizations.

      Example:

      .. code-block:: python

         def title_case(s):
             return s.title() if s else ''

         # Register our custom function.
         db.create_function(title_case)

         db.execute('select title_case(?)', ('heLLo wOrLd',)).fetchone()
         # ('Hello World',)

   .. method:: create_aggregate(agg, name=None, nargs=-1, deterministic=True)

      Create or remove a user-defined SQL aggregate function.

      :param agg:
          A class implementing the aggregate API. Must implement the following
          methods:

          * ``step()``: Add a row to the aggregate.
          * ``finalize()``: Return the final result of the aggregate as
            a type natively supported by SQLite.

          The number of arguments that the ``step()`` method must accept
          is controlled by *n_arg*.

          Set to ``None`` to remove an existing SQL aggregate function.
      :type agg: class | None
      :param str name: name of the SQL aggregate function. If unspecified, the
          name of the Python class will be used.
      :param int n_arg:
          The number of arguments the SQL aggregate function can accept.
          If ``-1``, it may take any number of arguments.

      Examples:

      .. code-block:: python

         class MD5(object):
             def initialize(self):
                 self.md5 = hashlib.md5()

             def step(self, value):
                 self.md5.update(value)

             def finalize(self):
                 return self.md5.hexdigest()

         class Product(object):
             '''Like SUM() except calculates cumulative product.'''
             def __init__(self):
                 self.product = 1

             def step(self, value):
                 self.product *= value

             def finalize(self):
                 return self.product

         # Register our custom aggregates.
         db.create_aggregate(MD5, 'md5', 1)
         db.create_aggregate(Product)

   .. method:: create_window_function(agg, name=None, nargs=-1, deterministic=True)

      Create or remove a user-defined SQL window function.

      :param agg:
          A class implementing the window function API. Must implement the
          following methods:

          * ``step()``: Add a row to the aggregate.
          * ``inverse()``: Inverse of the ``step`` method.
          * ``value()``: Return the current value of the window function.
          * ``finalize()``: Return the final result of the window function as
            a type natively supported by SQLite.

          The number of arguments that the ``step()`` and ``inverse()`` methods
          must accept is controlled by *n_arg*.

          Set to ``None`` to remove an existing SQL window function.
      :type agg: class | None
      :param str name: name of the SQL window function. If unspecified, the
          name of the Python class will be used.
      :param int n_arg:
          The number of arguments the SQL window function can accept.
          If ``-1``, it may take any number of arguments.

      .. code-block:: python

         class MySum(object):
             def __init__(self):
                 self._value = 0

             def step(self, value):
                 self._value += value

             def inverse(self, value):
                 self._value -= value

             def value(self):
                 return self._value

             def finalize(self):
                 return self._value

         # Register our custom window function (roughly identical to SUM).
         db.create_window_function(MySum, 'mysum', 1, True)

   .. method:: create_collation(fn, name)

      Create a collation named *name* using the collating function *fn*.
      *fn* is passed two :class:`string <str>` arguments, and it should return
      an :class:`integer <int>`.

      * ``1`` if the first is ordered higher than the second
      * ``-1`` if the first is ordered lower than the second
      * ``0`` if they are ordered equal

      :param fn:
          A callable that is called when comparing values for ordering.
          Set to ``None`` to remove an existing collation.
      :type fn: callback | None
      :param str name: name of the SQL collation. If unspecified, the name of
          the Python function will be used.

      The following example shows a reverse sorting collation:

      .. code-block:: python

         def collate_reverse(string1, string2):
             if string1 == string2:
                 return 0
             elif string1 < string2:
                 return 1
             else:
                 return -1

         db.create_collation(collate_reverse, 'reverse')

   .. method:: commit_hook(fn)

      Register a callback to be executed whenever a transaction is committed
      on the current connection. The callback accepts no parameters and the
      return value is ignored.

      However, if the callback raises a :class:`ValueError`, the transaction
      will be aborted and rolled-back.

      :param fn: callable or ``None`` to clear the current hook.
      :type fn: callable | None

      Example:

      .. code-block:: python

          db = connect(':memory:')

          # Example that aborts all COMMITs between midnight and 12:59:59am.
          def on_commit():
              if datetime.now().hour == 0:
                  raise ValueError('No changes allowed this late.')

          db.commit_hook(on_commit)

   .. method:: rollback_hook(fn)

      Register a callback to be executed whenever a transaction is rolled
      back on the current connection. The callback accepts no parameters and
      the return value is ignored.

      :param fn: callable or ``None`` to clear the current hook.
      :type fn: callable | None

      Example:

      .. code-block:: python

          @db.on_rollback
          def on_rollback():
              logger.info('Rolling back changes')

   .. method:: update_hook(fn)

      :param fn: callable or ``None`` to clear the current hook.
      :type fn: callable | None

      Register a callback to be executed whenever the database is written to
      (via an *UPDATE*, *INSERT* or *DELETE* query). The callback should
      accept the following parameters:

      * ``query`` - the type of query, either *INSERT*, *UPDATE* or *DELETE*.
      * database name - the default database is named *main*.
      * table name - name of table being modified.
      * rowid - the rowid of the row being modified.

      The callback's return value is ignored.

      Example:

      .. code-block:: python

         def on_update(query_type, db, table, rowid):
             # e.g. INSERT row 3 into table users.
             logger.info('%s row %s into table %s', query_type, rowid, table)

         db.update_hook(on_update)

   .. method:: authorizer(fn)

      :param fn: callable or ``None`` to clear the current authorizer.
      :type fn: callable | None
      :return:
          one of :data:`SQLITE_OK`, :data:`SQLITE_IGNORE` or :data:`SQLITE_DENY`.

          .. seealso:: :ref:`authorizer-flags`

      Register an authorizer callback. Authorizer callbacks must accept 5
      parameters, which vary depending on the operation being checked.

      * op: operation code, e.g. :data:`SQLITE_INSERT`.
      * p1: operation-specific value, e.g. table name for :data:`SQLITE_INSERT`.
      * p2: operation-specific value.
      * p3: database name, e.g. ``"main"``.
      * p4: inner-most trigger or view responsible for the access attempt if
        applicable, else ``None``.

      See `sqlite authorizer documentation <https://www.sqlite.org/c3ref/c_alter_table.html>`_
      for description of authorizer codes and values for parameters p1 and p2.

      The authorizer callback must return one of:

      * :data:`SQLITE_OK`: allow operation.
      * :data:`SQLITE_IGNORE`: allow statement compilation but prevent
        the operation from occuring.
      * :data:`SQLITE_DENY`: prevent statement compilation.

      Only a single authorizer can be in place on a database connection at a time.

      Example:

      .. code-block:: python

         # Prevent any updates to the log table.
         def prevent_updating_log(op, p1, p2, p3, p4):
             if op == SQLITE_UPDATE and p1 == 'log':
                 return SQLITE_DENY
             return SQLITE_OK

         db.authorizer(prevent_updating_log)

         # raises OperationalError - not authorized (code=23).
         db.execute('update log set status=? where id=?', (0, 1))

   .. method:: trace(fn, mask=2)

      :param fn: callable or ``None`` to clear the current trace hook.
      :param int mask: mask of what types of events to trace. Default value
          corresponds to ``SQLITE_TRACE_PROFILE``.

      Mask must consist of one or more of the following constants combined with
      bitwise-or:

      * :data:`SQLITE_TRACE_STMT`
      * :data:`SQLITE_TRACE_PROFILE`
      * :data:`SQLITE_TRACE_ROW`
      * :data:`SQLITE_TRACE_CLOSE`

      Register a trace hook. Trace callback must accept 4 parameters, which
      vary depending on the operation being traced:

      * event: type of event, e.g. ``SQLITE_TRACE_PROFILE``.
      * sid: memory address of statement (only ``SQLITE_TRACE_CLOSE``), else -1.
      * sql: SQL string (only ``SQLITE_TRACE_STMT``), else None.
      * ns: estimated number of nanoseconds the statement took to run (only
        ``SQLITE_TRACE_PROFILE``), else -1.

      See `sqlite_trace_v2 <https://sqlite.org/c3ref/c_trace.html>`_ for
      more details on trace modes and parameters.

      Any return value from callback is ignored.

   .. method:: progress(fn, n=1)

      :param fn: callable or ``None`` to clear the current progress handler.
      :type fn: callable | None
      :param int n: approximate number of VM instructions to execute between
        calls to the progress handler.

      Register a progress handler (``sqlite3_progress_handler``).

      Callback takes zero arguments and returns ``0`` to allow progress to
      continue or any non-zero value to interrupt progress.

      Example:

      .. code-block:: python

         def allow_interrupt():
             if halt_requested:
                 return 1  # Triggers an interrupt.
             return SQLITE_OK

         # Install our progress handler.
         db.progress(allow_interrupt)

         # Begin a very long database operation, allow the user to interrupt.
         try:
             with db.atomic():
                 db.execute(...)
         except OperationalError:
             # e.g. OperationalError: interrupted, code=9
             print('Query was interrupted.')

         # Remove the progress handler.
         db.progress(None)

   .. method:: set_busy_handler(timeout=5.0)

      :param float timeout: seconds to retry acquiring write lock before raising
          a :class:`OperationalError` when table is locked.

      Register a custom busy-handler that introduces jitter to help prevent
      multiple concurrent executions from sleeping and blocking in lock-step.
      Also retries more frequently than the standard implementation.

   .. method:: optimize(debug=False, run_tables=True, set_limit=True, check_table_sizes=False, dry_run=False)

      :param bool debug: debug-mode, do not actually perform any optimizations,
         instead print one line of text for each optimization that would have
         been done.
      :param bool run_tables: run ANALYZE on tables that might benefit from it.
      :param bool set_limit: when running ANALYZE set a temporary analysis
         limit to prevent excess run-time.
      :param bool check_table_sizes: check size of all tables, not just those
         that have changed recently, to see if any would benefit from ANALYZE.
      :param bool dry_run: see all optimizations that would have been
         performed without doing them.

      Wrapper around ``PRAGMA optimize``.

      See `optimize documentation <https://www.sqlite.org/pragma.html#pragma_optimize>`_.

   .. method:: attach(filename, name)

      :param str filename: database filename.
      :param str name: name for attached database.
      :raises: :class:`OperationalError` if database could not be attached.

      Example:

      .. code-block:: python

         db.attach('/path/to/secondary.db', 'secondary')

         curs = db.execute('select * from secondary.some_table')

   .. method:: detach(name)

      :param str name: name of attached database to disconnect.
      :raises: :class:`OperationalError` if database not attached.

      Example:

      .. code-block:: python

         db.detach('secondary')

   .. method:: database_list()

      :return: ``list`` of all databases active on the connection.

   .. method:: set_main_db_name(name)

      :param str name: new name for main database.

   .. method:: set_autocheckpoint(n)

      :param int n: set WAL auto-checkpoint.

   .. method:: checkpoint(full=False, truncate=False, name=None)

      By default will use ``SQLITE_CHECKPOINT_PASSIVE``.

      :param bool full: use ``SQLITE_CHECKPOINT_FULL``
      :param bool truncate: use ``SQLITE_CHECKPOINT_TRUNCATE``
      :param str name: database name to checkpoint, *optional*.

      See `sqlite3_wal_checkpoint_v2 <https://sqlite.org/c3ref/wal_checkpoint_v2.html>`_
      for details on the parameters and their behavior.

   .. method:: set_load_extension(enabled)
   .. method:: get_load_extension()

      Enable or disable run-time loadable extensions.

   .. method:: set_foreign_keys_enabled(enabled)
   .. method:: get_foreign_keys_enabled()

      Enable or disable foreign-key constraint enforcement. For historical
      reasons, many builds of SQLite do not ship with foreign-key constraints
      enabled by default.

   .. method:: set_triggers_enabled(enabled)
   .. method:: get_triggers_enabled()

      Enable or disable triggers from being executed.

   .. method:: setlimit(category, limit)
               getlimit(category)

      Set or get the value of a run-time limit. Limits are defined by the
      :ref:`limit-constants`.

      See `sqlite3 run-time limit categories <https://www.sqlite.org/c3ref/c_limit_attached.html#sqlitelimitattached>`_
      for details.


Cursor
------

.. class:: Cursor(conn)

   Cursors are created by calling :meth:`Connection.cursor` or by executing a
   query with :meth:`Connection.execute`.

   :param Connection conn: connection the cursor is bound to.

   .. attribute:: row_factory

      Factory for creating row instances from query results, e.g. :class:`Row`.
      Uses the value from the :attr:`Connection.row_factory` by default.

      Example:

      .. code-block:: python

         cursor = db.cursor()
         cursor.row_factory = cysqlite.Row
         cursor.execute('SELECT * FROM users')
         for row in cursor:
             print(row['name'])  # Access by column name

   .. method:: execute(sql, params=None)

      Execute the given *sql* and *params*.

      :param str sql: SQL query to execute.
      :param params: parameters for query (optional).
      :type params: tuple, list, sequence, dict, or ``None``.
      :return: self
      :rtype: :class:`Cursor`

      Example:

      .. code-block:: python

         curs = db.cursor()

         curs.execute('create table kv ("id" integer primary key, "key", "value")')

         # Iterate over results from a bulk-insert.
         curs.execute('insert into kv (key, value) values (?, ?), (?, ?) '
                      'returning id, key', ('k1', 'v1', 'k2', 'v2'))
         for (i, k) in curs:
             print(f'inserted {k} with id={i}')

         # Retrieve a single row result.
         curs.execute('select * from kv where id = :pk', {'pk': 1})
         row = curs.fetchone()
         print(f'retrieved row 1: {row}')

         # Empty result set.
         curs.execute('select * from kv where id = 0')
         assert curs.fetchone() is None
         assert curs.fetchall() == []

   .. method:: executemany(sql, seq_of_params)

      Execute the given *sql* repeatedly for each parameter group in *seq_of_params*.

      Queries executed by :meth:`~Connection.executemany` must not return any
      result rows, or this will result in an :class:`OperationalError`.

      :param str sql: SQL query to execute.
      :param seq_of_params: iterable of parameters to repeatedly execute the
        query with.
      :type seq_of_params: sequence of tuple, list, sequence, dict, or ``None``.
      :return: self
      :rtype: :class:`Cursor`

      Example:

      .. code-block:: python

         curs = db.cursor()

         curs.execute('create table kv ("id" integer primary key, "key", "value")')

         curs.executemany('insert into kv (key, value) values (?, ?)',
                          [('k1', 'v1'), ('k2', 'v2'), ('k3', 'v3')])
         print(curs.lastrowid)  # 3.
         print(curs.rowcount)  # 3.

         curs.executemany('insert into kv (key, value) values (:k, :v)',
                          [{'k': 'k4', 'v': 'v4'}, {'k': 'k5', 'v': 'v5'}])
         print(curs.lastrowid)  # 5.
         print(curs.rowcount)  # 2.

   .. method:: executescript(sql)

      Execute the SQL statement(s) in *sql*.

      :param str sql: One or more SQL statements to execute in a script.
      :return: self
      :rtype: :class:`Cursor`

      Example:

      .. code-block:: python

         curs = db.cursor()
         curs.executescript("""
             begin;
             create table users (
                id integer not null primary key,
                name text not null,
                email text not null);
             create indexusers_email ON users (email);

             create table tweets (
                id integer not null primary key,
                content text not null,
                user_id integer not null references users (id),
                timestamp integer not null);

             commit;
         """)

   .. method:: __iter__()
               __next__()

      Cursors support the iterator protocol.

      Example:

      .. code-block:: python

         curs = db.execute('select username from users')
         for row in curs:
             print(row[0])

   .. method:: fetchone()

      Return the next row from the query result set. By default rows are
      returned as ``tuple``, but row type can be controlled by setting
      :attr:`Connection.row_factory`.

      If no results are available or cursor has been consumed returns ``None``.

      Example:

      .. code-block:: python

         curs = db.execute('select 1')
         print(curs.fetchone())  # (1,)
         print(curs.fetchone())  # None

   .. method:: fetchall()

      Fetch all rows from the query result set. By default rows are returned as
      ``tuple``, but row type can be controlled by setting
      :attr:`Connection.row_factory`.

      If no results are available or cursor has been consumed returns ``[]``.

      Example:

      .. code-block:: python

         curs = db.execute('select 1')
         print(curs.fetchall())  # [(1,)]
         print(curs.fetchall())  # []

   .. method:: value()

      Fetch a single scalar value from the query result set. If no results are
      available or cursor has been consumed returns ``None``.

      Example:

      .. code-block:: python

         curs = db.execute('select 1')
         print(curs.value())  # 1
         print(curs.value())  # None

   .. method:: close()

      Close the cursor and release associated resources.

      .. note::

         It is not necessary to explicitly close a cursor. Cursors will be
         closed during garbage collection automatically.

   .. method:: columns()

      Return a list of the names of columns in the result data.

   .. attribute:: description

      Return a DB-API style description of the row-data for the current query.
      cysqlite returns a list of tuples containing the individual column names
      for the query.

   .. attribute:: lastrowid

      Return the last-inserted rowid for the cursor.

   .. attribute:: rowcount

      Return the count of rows modified by the last operation. Returns ``-1``
      for queries that do not modify data.

Row
---

.. class:: Row(cursor, data)

   :param Cursor cursor:
   :param tuple data:

   Highly-optimized row class compatible with ``sqlite3.Row``, intended to be
   used with :attr:`Connection.row_factory` or :attr:`Cursor.row_factory`.
   Supports the following access patterns:

   * Item lookup using column indices.
   * Dict lookup using column names.
   * Attribute access using attribute names.

   Additionally supports dict-like interface methods.

   .. method:: __len__()
               __eq__()
               keys()
               values()
               items()
               as_dict()

   Example:

   .. code-block:: python

      db = cysqlite.connect('app.db')
      db.row_factory = cysqlite.Row

      curs = db.execute('select * from users')
      row = curs.fetchone()

      print(row)
      # <Row(id=1, username='charles', active=1)>

      print(row.username)
      # charles

      print(row['active'])
      # 1

      print(row[0])
      # 1

      print(list(row))
      # [1, 'charles', 1]

Blob
----

.. class:: Blob(conn, table, column, rowid, read_only=False, database=None)

   Open a blob handle, stored in the given table/column/row, for incremental
   I/O. To allocate storage for new data, you can use the SQL ``zeroblob(n)``
   function, where *n* is the desired size in bytes.

   :param conn: :class:`Connection` instance.
   :param str table: Name of table being accessed.
   :param str column: Name of column being accessed.
   :param int rowid: Primary-key of row being accessed.
   :param bool read_only: Prevent any modifications to the blob data.
   :param str database: Name of database containing table, *optional*.

   .. code-block:: python

      db = connect(':memory:')
      db.execute('create table raw_data (id integer primary key, data blob)')

      # Allocate 100MB of space for writing a large file incrementally:
      db.execute('insert into raw_data (data) values (zeroblob(?))',
                 (1024 * 1024 * 100,))
      rowid = db.last_insert_rowid()

      # Now we can open the row for incremental I/O:
      blob = Blob(db, 'rawdata', 'data', rowid)

      # Read from the file and write to the blob in chunks of 4096 bytes.
      while True:
          data = file_handle.read(4096)
          if not data:
              break
          blob.write(data)

      bytes_written = blob.tell()
      blob.close()

   .. method:: read(n=None)

      :param int n: Only read up to *n* bytes from current position in file.
      :return: Blob data
      :rtype: bytes

      Read up to *n* bytes from the current position in the blob file. If *n*
      is not specified, the entire blob will be read.

   .. method:: seek(offset, frame_of_reference=0)

      :param int offset: Seek to the given offset in the file.
      :param int frame_of_reference: Seek relative to the specified frame of reference.

      Values for ``whence``:

      * ``0``: beginning of file
      * ``1``: current position
      * ``2``: end of file

      Attempts to seek beyond the start or end of the file raise ``ValueError``.

   .. method:: tell()

      Return current offset within the file.

   .. method:: write(data)

      :param buffer data: Data to be written: buffer (e.g. ``bytes``,
         ``bytearray``, ``memoryview``) or ``str`` (will be encoded as UTF8)

      Writes the given data, starting at the current position in the file. If
      the data is too large for the blob to store, raises ``ValueError``.

   .. method:: close()

      Close the file and free associated resources.

   .. method:: reopen(rowid)

      :param int rowid: Primary key of row to open.

      If a blob has already been opened for a given table/column, you can use
      the :meth:`~Blob.reopen` method to re-use the same :class:`Blob`
      object for accessing multiple rows in the table.

TableFunction
-------------

Implement a user-defined table-valued function. Unlike :meth:`Connection.create_function`
or :meth:`Connection.create_aggregate`, which return a single scalar value, a
table-valued function can return any number of rows of tabular data.

Example read-only :class:`TableFunction`:

.. code-block:: python

   from cysqlite import TableFunction

   class Series(TableFunction):
       name = 'series'  # Specify name - if empty class name is used.

       # Name of columns in each row of generated data.
       columns = ['value']

       # Name of parameters the function may be called with.
       params = ['start', 'stop', 'step']

       def initialize(self, start=0, stop=None, step=1):
           """
           Table-functions declare an initialize() method, which is
           called with whatever arguments the user has called the
           function with.
           """
           self.start = self.current = start
           self.stop = stop or float('Inf')
           self.step = step

       def iterate(self, idx):
           """
           Iterate is called repeatedly by the SQLite database engine
           until the required number of rows has been read **or** the
           function raises a `StopIteration` signalling no more rows
           are available.
           """
           if self.current > self.stop:
               raise StopIteration

           ret, self.current = self.current, self.current + self.step
           return (ret,)

   # Register the table-function with our database.
   db = connect(':memory:')
   Series.register(db)

   # Usage:
   cursor = db.execute('select * from series(?, ?, ?)', (0, 5, 2))
   for row in cursor:
       print(row)
   # (0,)
   # (2,)
   # (4,)

Example :class:`TableFunction` that supports INSERT/UPDATE/DELETE queries:

.. code-block:: python

   class MemStore(TableFunction):
       """
       In-memory key/value store exposed as a virtual-table.
       """
       name = 'memstore'
       columns = [
           ('id', 'INTEGER'),
           ('key', 'TEXT'),
           ('value', 'TEXT')]
       params = []

       _data = {}
       _next_id = 1

       def initialize(self, **filters):
           pass

       def iterate(self, idx):
           keys = sorted(self._data)
           if idx >= len(keys):
               raise StopIteration

           rowid = keys[idx]
           row = self._data[rowid]

           # Return a 2-tuple of (rowid, row-data) to specify rowid explicitly.
           return (rowid, (row['id'], row['key'], row['value']))

       def insert(self, rowid, values):
           # rowid might be None, so we auto-generate
           if rowid is None:
               rowid = self._next_id
               MemStore._next_id += 1
           else:
               rowid = int(rowid)
               if rowid >= MemStore._next_id:
                   MemStore._next_id = rowid + 1

           if len(values) < 3:
               raise ValueError('Expected 3 values, got %s' % len(values))

           u_rowid, key, value = values
           self._data[rowid] = {
               'id': int(u_rowid) if u_rowid is not None else rowid,
               'key': str(key) if key is not None else key,
               'value': str(value) if value is not None else value,
           }

           return rowid

       def update(self, old_rowid, new_rowid, values):
           old_rowid = int(old_rowid)
           new_rowid = int(new_rowid)

           if old_rowid not in self._data:
               raise ValueError('Row %s not found' % old_rowid)

           if len(values) < 3:
               raise ValueError('Expected 3 values, got %s' % len(values))

           uid, key, value = values
           if uid:
               new_rowid = uid

           if old_rowid != new_rowid:
               # User updated rowid, move data.
               self._data[new_rowid] = self._data.pop(old_rowid)
               rowid = new_rowid
           else:
               rowid = old_rowid

           if uid:
               self._data[rowid]['id'] = int(uid)
           if key is not None:
               self._data[rowid]['key'] = key
           if value is not None:
               self._data[rowid]['value'] = value

       def delete(self, rowid):
           rowid = int(rowid)
           if rowid not in self._data:
               raise ValueError('Row %s not found' % rowid)
           del self._data[rowid]

   # Register the table-function with our database.
   db = connect(':memory:')
   MemStore.register(db)

   # Usage:
   db.execute('insert into memstore (id, key, value) values (?, ?, ?)',
              (1, 'k1', 'v1'))
   db.execute('insert into memstore (key, value) values (?, ?), (?, ?)',
              ('k2', 'v2', 'k3', 'v3'))

   assert db.last_insert_rowid() == 3

   for row in db.execute('select * from memstore where value != ?' ('v2',)):
       print(row)

   # (1, 'k1', 'v1')
   # (3, 'k3', 'v3')

   db.execute('update memstore set value = ? where key = ?', ('v2y', 'k2'))
   db.execute('update memstore set value = value || ?', ('z',))

   for row in db.execute('select * from memstore'):
       print(row)

   # (1, 'k1', 'v1z')
   # (2, 'k2', 'v1yz')
   # (3, 'k3', 'v3z')

   db.execute('delete from memstore where key = ?', ('k2',))
   assert db.changes() == 1

   db.execute('update memstore set id = ? where id = ?', (4, 3))
   assert db.changes() == 1

   db.execute('delete from memstore where key = ?', ('not-here',))
   assert db.changes() == 0

   for row in db.execute('select * from memstore'):
       print(row)

   # (1, 'k1', 'v1z')
   # (4, 'k3', 'v3z')

   print(MemStore._data)
   # {1: {'id': 1, 'key': 'k1', 'value': 'v1z'},
   #  4: {'id': 4, 'key': 'k3', 'value': 'v3z'}}


.. note::
   A :class:`TableFunction` must be registered with a database connection
   before it can be used.

.. class:: TableFunction

   :class:`TableFunction` implementations must provide two attributes and
   implement two methods, described below.

   .. attribute:: columns

      A list containing the names of the columns for the data returned by the
      function. For example, a function that is used to split a string on a
      delimiter might specify 3 columns: ``[substring, start_idx, end_idx]``.

      To specify data-types for your columns, you can specify a list of
      2-tuples of ``(column name, type)``, e.g.:

      .. code-block:: python

         columns = [('key', 'text'), ('data', 'blob')]

   .. attribute:: params

      The names of the parameters the function may be called with. All
      parameters, including optional parameters, should be listed. For
      example, a function that is used to split a string on a delimiter might
      specify 2 params: ``[string, delimiter]``.

   .. attribute:: name

      *Optional* - specify the name for the table function. If not provided,
      name will be taken from the class name.

   .. attribute:: print_tracebacks = True

      Print a full traceback for any errors that occur in the table-function's
      callback methods. When set to False, only the generic
      :class:`OperationalError` will be visible.

   .. method:: initialize(**parameter_values)

       :param parameter_values: Parameters the function was called with.
       :returns: No return value.

       The ``initialize`` method is called to initialize the table function
       with the parameters the user specified when calling the function.

   .. method:: iterate(idx)

       :param int idx: current iteration step, or more specifically rowid.
       :returns: A tuple of row data corresponding to the columns named
           in the :attr:`~TableFunction.columns` attribute.

           Implementations may explicitly specify a ``rowid`` by returning a
           2-tuple of ``(rowid, (row, data, here))``.
       :raises StopIteration: To signal that no more rows are available.

       This function is called repeatedly and returns successive rows of data.
       The function may terminate before all rows are consumed (especially if
       the user specified a ``LIMIT`` on the results). Alternatively, the
       function can signal that no more data is available by raising a
       ``StopIteration`` exception.

   .. method:: insert(rowid, values)

      :param int rowid: rowid for inserted data, may be ``None``.
      :param list values: values to be inserted.
      :return: rowid of new data.
      :rtype: int

      Handle INSERT into the virtual table.

      If omitted, the virtual table will not support INSERT queries.

   .. method:: update(old_rowid, new_rowid, values)

      :param int old_rowid: rowid for data being updated.
      :param int new_rowid: new rowid for data (usually same as old_rowid).
      :param list values: values to be updated.
      :return: no return value.

      Handle UPDATE of a row in the virtual table.

      If omitted, the virtual table will not support UPDATE queries.

   .. method:: delete(rowid)

      :param int rowid: rowid to be deleted.
      :return: no return value.

      Handle DELETE of a row in the virtual table.

      If omitted, the virtual table will not support DELETE queries.

   .. classmethod:: register(conn)

       :param Connection conn: Connection to register table function.

       Register the table function with the :class:`Connection`. Table-valued
       functions **must** be registered before they can be used in a query.

       Example:

       .. code-block:: python

           class MyTableFunction(TableFunction):
               name = 'my_func'
               # ... other attributes and methods ...

           db = connect(':memory:')

           MyTableFunction.register(db)

Helpers
-------

cysqlite includes a handful of miscellaneous helpers for various things that
may come up when you're using SQLite.

.. function:: rank_bm25(...)

   `Okapi BM25 <https://en.wikipedia.org/wiki/Okapi_BM25>`_ ranking algorithm
   for use with SQLite full-text search extensions (FTS4 and FTS5 only).

   Parameters are opaque as function is intended to be called with the output
   of the SQLite `matchinfo(table, 'pcnalx')` function, which provides the
   required metadata needed to rank the search results.

   .. warning::
        You must specify ``'pcnalx'`` as the output format for ``matchinfo()``
        to ensure that the statistics are read from the index correctly.

   Usage:

   .. code-block:: python

      # Create an FTS4 virtual table to search.
      db.execute('create virtual table search using fts4 '
                 '(title, content, tokenize="porter")')

      # Insert sample data into search index.
      db.execute(
          'insert into search (docid, title, content) values (?, ?, ?)',
          (1, 'some title', 'text I wish to search'))

      # Register the bm25 rank function.
      db.create_function(rank_bm25)

      # Perform search and rank results using BM25. The title will be
      # weighted as 2x more important than the body content, for example.
      # Search results are returned sorted most-relevant first.
      curs = db.execute("""
          select docid, title,
                 rank_bm25(matchinfo(search, ?), ?, ?) as score
          from search where search match ?
          order by score""",
          ('pcnalx', 2.0, 1.0, search_query))

      for docid, title, score in curs:
          print('Document "%s" matched - score %s' % (title, score))

      # No weighting, both columns equally scored. Results returned
      # most-relevant first.
      curs = db.execute("""
          select docid, title,
                 rank_bm25(matchinfo(search, ?)) as score
          from search where search match ?
          order by score""",
          ('pcnalx', search_query))

      for docid, title, score in curs:
          print('Document "%s" matched - score %s' % (title, score))

.. function:: rank_lucene(...)

   Works similarly to :func:`rank_bm25` but uses a slightly different algorithm
   derived from Lucene. See the above section on :func:`rank_bm25` for usage
   example.

.. function:: levenshtein_dist(a, b)

   C implementation of `Levenshtein Distance <https://en.wikipedia.org/wiki/Levenshtein_distance>`_
   algorithm for comparing similarity of two strings. Useful for fuzzy matching
   of strings.

   Usage:

   .. code-block:: python

      db = connect(':memory:')

      db.create_function(levenshtein_dist, 'levdist')

      print(db.execute_scalar(
          'select levdist(?, ?)',
          ('cysqlite', 'cyqslite'))
      # 2.

.. function:: damerau_levenshtein_dist(a, b)

   C implementation of `Damerau Levenshtein Distance <https://en.wikipedia.org/wiki/Damerau%E2%80%93Levenshtein_distance>`_
   algorithm for comparing similarity of two strings. Useful for fuzzy matching
   of strings.

   Usage:

   .. code-block:: python

      db = connect(':memory:')

      db.create_function(damerau_levenshtein_dist, 'dlevdist')

      print(db.execute_scalar(
          'select dlevdist(?, ?)',
          ('cysqlite', 'cyqslite'))
      # 1.

.. class:: median()

   C implementation of an **aggregate** and **window** function that calculates
   the median of a sequence of values.

   Usage:

   .. code-block:: python

      db = connect(':memory:')

      db.create_window_function(median)

      # Get the employee salaries along w/median salary for their dept.
      curs = db.execute_scalar("""
          select
            department,
            employee,
            salary,
            median(salary) over (partition by department) '
          from employees
          order by department""")


Exceptions
----------

Exceptions follow the `DB-API 2.0 <https://peps.python.org/pep-0249/>`_
exception hierarchy.

.. class:: SqliteError

   Exception that is the base class of all other error exceptions. You can use
   this to catch all errors with one single except statement.

.. class:: InterfaceError

   Exception raised for errors that are related to the database interface
   rather than the database itself.

   *Currently not used.*

.. class:: DatabaseError

   Exception raised for errors that are related to the database. The following
   exception classes are all drived from :class:`DatabaseError`.

.. class:: DataError

   Exception raised for errors that are due to problems with the processed data
   like division by zero, numeric value out of range, etc.

   *Currently not used.*

.. class:: OperationalError

   Exception raised for errors that are related to the database’s operation.
   Raised in most cases for errors when working with the database.

   **Corresponds to most SQLite error codes.**

.. class:: IntegrityError

   Exception raised when the relational integrity of the database is affected,
   e.g. a foreign key check fails or a unique constraint fails.

   Corresponds to ``SQLITE_CONSTRAINT`` errors.

.. class:: InternalError

   Exception raised when the database encounters an internal error.

   Corresponds to ``SQLITE_INTERNAL`` errors.

.. class:: ProgrammingError

   Exception raised for programming errors.

.. class:: NotSupportedError

   Exception raised in case a method or database API was used which is not
   supported by the database.

   *Currently not used.*


Constants
---------

.. attribute:: SQLITE_OK
    :type: int
    :value: 0

    General success response code used by SQLite.

Error codes
^^^^^^^^^^^

.. data:: SQLITE_ERROR
          SQLITE_INTERNAL
          SQLITE_PERM
          SQLITE_ABORT
          SQLITE_BUSY
          SQLITE_LOCKED
          SQLITE_NOMEM
          SQLITE_READONLY
          SQLITE_INTERRUPT
          SQLITE_IOERR
          SQLITE_CORRUPT
          SQLITE_NOTFOUND
          SQLITE_FULL
          SQLITE_CANTOPEN
          SQLITE_PROTOCOL
          SQLITE_EMPTY
          SQLITE_SCHEMA
          SQLITE_TOOBIG
          SQLITE_CONSTRAINT
          SQLITE_MISMATCH
          SQLITE_MISUSE
          SQLITE_NOLFS
          SQLITE_AUTH
          SQLITE_FORMAT
          SQLITE_RANGE
          SQLITE_NOTADB

.. _sqlite-status-flags:

Sqlite Status Flags
^^^^^^^^^^^^^^^^^^^

.. seealso::
   :func:`status`
      Read SQLite status, uses ``sqlite3_status`` internally.

.. data:: SQLITE_STATUS_MEMORY_USED
          SQLITE_STATUS_PAGECACHE_USED
          SQLITE_STATUS_PAGECACHE_OVERFLOW
          SQLITE_STATUS_SCRATCH_USED
          SQLITE_STATUS_SCRATCH_OVERFLOW
          SQLITE_STATUS_MALLOC_SIZE
          SQLITE_STATUS_PARSER_STACK
          SQLITE_STATUS_PAGECACHE_SIZE
          SQLITE_STATUS_SCRATCH_SIZE
          SQLITE_STATUS_MALLOC_COUNT

.. seealso::
   :meth:`Connection.status`
      Read SQLite database status, uses ``sqlite3_db_status`` internally.

.. data:: SQLITE_DBSTATUS_LOOKASIDE_USED
          SQLITE_DBSTATUS_CACHE_USED
          SQLITE_DBSTATUS_SCHEMA_USED
          SQLITE_DBSTATUS_STMT_USED
          SQLITE_DBSTATUS_LOOKASIDE_HIT
          SQLITE_DBSTATUS_LOOKASIDE_MISS_SIZE
          SQLITE_DBSTATUS_LOOKASIDE_MISS_FULL
          SQLITE_DBSTATUS_CACHE_HIT
          SQLITE_DBSTATUS_CACHE_MISS
          SQLITE_DBSTATUS_CACHE_WRITE
          SQLITE_DBSTATUS_DEFERRED_FKS

.. _sqlite-connection-flags:

Sqlite Connection Flags
^^^^^^^^^^^^^^^^^^^^^^^

.. seealso::
   :class:`Connection` and :func:`connect`
      Flags for controlling how connection is opened.

.. data:: SQLITE_OPEN_READONLY
          SQLITE_OPEN_READWRITE
          SQLITE_OPEN_CREATE
          SQLITE_OPEN_URI
          SQLITE_OPEN_MEMORY
          SQLITE_OPEN_NOMUTEX
          SQLITE_OPEN_FULLMUTEX
          SQLITE_OPEN_SHAREDCACHE
          SQLITE_OPEN_PRIVATECACHE

VFS-only Connection Flags
^^^^^^^^^^^^^^^^^^^^^^^^^

Support for these flags is dependent on the VFS providing an implementation.

.. data:: SQLITE_OPEN_DELETEONCLOSE
          SQLITE_OPEN_EXCLUSIVE
          SQLITE_OPEN_AUTOPROXY
          SQLITE_OPEN_WAL
          SQLITE_OPEN_MAIN_DB
          SQLITE_OPEN_TEMP_DB
          SQLITE_OPEN_TRANSIENT_DB
          SQLITE_OPEN_MAIN_JOURNAL
          SQLITE_OPEN_TEMP_JOURNAL
          SQLITE_OPEN_SUBJOURNAL
          SQLITE_OPEN_MASTER_JOURNAL

.. _authorizer-flags:

Authorizer Constants
^^^^^^^^^^^^^^^^^^^^

.. seealso::
   Setting an authorizer callback.
      :meth:`Connection.authorizer`

Return values (along with :data:`SQLITE_OK`) for authorizer callback.

.. data:: SQLITE_DENY
          SQLITE_IGNORE

Operations reported to authorizer callback.

.. data:: SQLITE_CREATE_INDEX
          SQLITE_CREATE_TABLE
          SQLITE_CREATE_TEMP_INDEX
          SQLITE_CREATE_TEMP_TABLE
          SQLITE_CREATE_TEMP_TRIGGER
          SQLITE_CREATE_TEMP_VIEW
          SQLITE_CREATE_TRIGGER
          SQLITE_CREATE_VIEW
          SQLITE_DELETE
          SQLITE_DROP_INDEX
          SQLITE_DROP_TABLE
          SQLITE_DROP_TEMP_INDEX
          SQLITE_DROP_TEMP_TABLE
          SQLITE_DROP_TEMP_TRIGGER
          SQLITE_DROP_TEMP_VIEW
          SQLITE_DROP_TRIGGER
          SQLITE_DROP_VIEW
          SQLITE_INSERT
          SQLITE_PRAGMA
          SQLITE_READ
          SQLITE_SELECT
          SQLITE_TRANSACTION
          SQLITE_UPDATE
          SQLITE_ATTACH
          SQLITE_DETACH
          SQLITE_ALTER_TABLE
          SQLITE_REINDEX
          SQLITE_ANALYZE
          SQLITE_CREATE_VTABLE
          SQLITE_DROP_VTABLE
          SQLITE_FUNCTION
          SQLITE_SAVEPOINT
          SQLITE_COPY
          SQLITE_RECURSIVE

.. _trace-flags:

Trace Constants
^^^^^^^^^^^^^^^

.. seealso::
   Setting a trace callback.
      :meth:`Connection.trace`

.. data:: SQLITE_TRACE_STMT
          SQLITE_TRACE_PROFILE
          SQLITE_TRACE_ROW
          SQLITE_TRACE_CLOSE

.. _limit-constants:

Limit Constants
^^^^^^^^^^^^^^^

.. seealso::
   Setting and getting limits.
      :meth:`Connection.setlimit` :meth:`Connection.getlimit`

.. data:: SQLITE_LIMIT_LENGTH
          SQLITE_LIMIT_SQL_LENGTH
          SQLITE_LIMIT_COLUMN
          SQLITE_LIMIT_EXPR_DEPTH
          SQLITE_LIMIT_COMPOUND_SELECT
          SQLITE_LIMIT_VDBE_OP
          SQLITE_LIMIT_FUNCTION_ARG
          SQLITE_LIMIT_ATTACHED
          SQLITE_LIMIT_LIKE_PATTERN_LENGTH
          SQLITE_LIMIT_VARIABLE_NUMBER
          SQLITE_LIMIT_TRIGGER_DEPTH
          SQLITE_LIMIT_WORKER_THREADS
