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

   .. attribute:: row_factory

      Factory for creating row instances from query results, e.g. :class:`Row`.
      By default rows are returned as ``tuple`` instances.

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
      :type params: tuple, list, sequence, or ``None``.
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

         # Retrieve a single row result.
         curs = db.execute('select * from kv where id = ?', (1, ))
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
      :type params: tuple, list, or sequence.
      :return: cursor object.
      :rtype: :class:`Cursor`

      Example:

      .. code-block:: python

         db.execute('create table kv ("id" integer primary key, "key", "value")')

         # Iterate over results from a bulk-insert.
         curs = db.executemany('insert into kv (key, value) values (?, ?)',
                               [('k1', 'v1'), ('k2', 'v2'), ('k3', 'v3')])
         print(curs.lastrowid)  # 3.
         print(curs.rowcount)  # 3.

   .. method:: execute_one(sql, params=None)

      Create a new :class:`Cursor` and call :meth:`~Cursor.execute` with the
      given *sql* and *params*. Returns the first result row, if one exists.

      :param str sql: SQL query to execute.
      :param params: parameters for query (optional).
      :type params: tuple, list, sequence, or ``None``.
      :return: a single row of data or ``None`` if no results.

      Example:

      .. code-block:: python

         row = db.execute_one('select * from users where id = ?', (1,))

   .. method:: execute_scalar(sql, params=None)

      Create a new :class:`Cursor` and call :meth:`~Cursor.execute` with the
      given *sql* and *params*. Returns the first value of the first result
      row, if one exists. Useful for aggregates or queries that only return a
      single value.

      :param str sql: SQL query to execute.
      :param params: parameters for query (optional).
      :type params: tuple, list, sequence, or ``None``.
      :return: a single value or ``None`` if no result.

      .. code-block:: python

         count = db.execute_scalar('select count(*) from users')

   .. method:: begin(lock=None)

      Begin a transaction.

      If a transaction is already active, raises :py:class:`OperationalError`.

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

      If no transaction is active, raises :py:class:`OperationalError`.

      .. seealso:: :meth:`Connection.atomic`

   .. method:: rollback()

      Roll-back the currently-active transaction.

      If no transaction is active, raises :py:class:`OperationalError`.

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
         print(db.status(C_SQLITE_STATUS_PAGECACHE_USED))
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

   .. method:: blob_open(table, column, rowid, read_only=False, dbname=None)

      Open a :class:`Blob` handle to an existing :abbr:`BLOB (Binary Large OBject)`.

      :param str table: table where blob is stored.
      :param str column: column where blob is stored.
      :param int rowid: id of row to open.
      :param bool read_only: open blob in read-only mode.
      :param str dbname: database name, *optional*.
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
          one of :data:`C_SQLITE_OK`, :data:`C_SQLITE_IGNORE` or :data:`C_SQLITE_DENY`.

          .. seealso:: :ref:`authorizer-flags`

      Register an authorizer callback. Authorizer callbacks must accept 5
      parameters, which vary depending on the operation being checked.

      * op: operation code, e.g. :data:`C_SQLITE_INSERT`.
      * p1: operation-specific value, e.g. table name for :data:`C_SQLITE_INSERT`.
      * p2: operation-specific value.
      * p3: database name, e.g. ``"main"``.
      * p4: inner-most trigger or view responsible for the access attempt if
        applicable, else ``None``.

      See `sqlite authorizer documentation <https://www.sqlite.org/c3ref/c_alter_table.html>`_
      for description of authorizer codes and values for parameters p1 and p2.

      The authorizer callback must return one of:

      * :data:`C_SQLITE_OK`: allow operation.
      * :data:`C_SQLITE_IGNORE`: allow statement compilation but prevent
        the operation from occuring.
      * :data:`C_SQLITE_DENY`: prevent statement compilation.

      Only a single authorizer can be in place on a database connection at a time.

      Example:

      .. code-block:: python

         # Prevent any updates to the log table.
         def prevent_updating_log(op, p1, p2, p3, p4):
             if op == C_SQLITE_UPDATE and p1 == 'log':
                 return C_SQLITE_DENY
             return C_SQLITE_OK

         db.authorizer(prevent_updating_log)

         # raises OperationalError - not authorized (code=23).
         db.execute('update log set status=? where id=?', (0, 1))

   .. method:: trace(fn, mask=2)

      :param fn: callable or ``None`` to clear the current trace hook.
      :param int mask: mask of what types of events to trace. Default value
          corresponds to ``SQLITE_TRACE_PROFILE``.

      Register a trace hook. Trace callback must accept 4 parameters, which
      vary depending on the operation being traced:

      * event: type of event, e.g. ``cysqlite.TRACE_PROFILE``.
      * sid: memory address of statement (only ``cysqlite.TRACE_CLOSE``), else -1.
      * sql: SQL string (only ``cysqlite.TRACE_STMT``), else None.
      * ns: estimated number of nanoseconds the statement took to run (only
        ``cysqlite.TRACE_PROFILE``), else -1.

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
             return C_SQLITE_OK

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

Cursor
------

.. class:: Cursor(conn)

   Cursors are created by calling :meth:`Connection.cursor` or by executing a
   query with :meth:`Connection.execute`.

   :param Connection conn: connection the cursor is bound to.

   .. method:: execute(sql, params=None)

      Execute the given *sql* and *params*.

      :param str sql: SQL query to execute.
      :param params: parameters for query (optional).
      :type params: tuple, list, sequence, or ``None``.
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
         curs.execute('select * from kv where id = ?', (1, ))
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
      :type params: tuple, list, or sequence.
      :return: self
      :rtype: :class:`Cursor`

      Example:

      .. code-block:: python

         curs = db.cursor()

         curs.execute('create table kv ("id" integer primary key, "key", "value")')

         # Iterate over results from a bulk-insert.
         curs.executemany('insert into kv (key, value) values (?, ?)',
                          [('k1', 'v1'), ('k2', 'v2'), ('k3', 'v3')])
         print(curs.lastrowid)  # 3.
         print(curs.rowcount)  # 3.

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

   .. py:method:: fetchall()

      Fetch all rows from the query result set. By default rows are returned as
      ``tuple``, but row type can be controlled by setting
      :attr:`Connection.row_factory`.

      If no results are available or cursor has been consumed returns ``[]``.

      Example:

      .. code-block:: python

         curs = db.execute('select 1')
         print(curs.fetchall())  # [(1,)]
         print(curs.fetchall())  # []

   .. py:method:: value()

      Fetch a single scalar value from the query result set. If no results are
      available or cursor has been consumed returns ``None``.

      Example:

      .. code-block:: python

         curs = db.execute('select 1')
         print(curs.value())  # 1
         print(curs.value())  # None

   .. py:method:: close()

      Close the cursor and release associated resources.

      .. note::

         It is not necessary to explicitly close a cursor. Cursors will be
         closed during garbage collection automatically.


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

.. attribute:: C_SQLITE_OK
    :type: int
    :value: 0

    General success response code used by SQLite.

Error codes
^^^^^^^^^^^

.. data:: C_SQLITE_ERROR
             C_SQLITE_INTERNAL
             C_SQLITE_PERM
             C_SQLITE_ABORT
             C_SQLITE_BUSY
             C_SQLITE_LOCKED
             C_SQLITE_NOMEM
             C_SQLITE_READONLY
             C_SQLITE_INTERRUPT
             C_SQLITE_IOERR
             C_SQLITE_CORRUPT
             C_SQLITE_NOTFOUND
             C_SQLITE_FULL
             C_SQLITE_CANTOPEN
             C_SQLITE_PROTOCOL
             C_SQLITE_EMPTY
             C_SQLITE_SCHEMA
             C_SQLITE_TOOBIG
             C_SQLITE_CONSTRAINT
             C_SQLITE_MISMATCH
             C_SQLITE_MISUSE
             C_SQLITE_NOLFS
             C_SQLITE_AUTH
             C_SQLITE_FORMAT
             C_SQLITE_RANGE
             C_SQLITE_NOTADB

.. _sqlite-status-flags:

Sqlite Status Flags
^^^^^^^^^^^^^^^^^^^

.. seealso::
   :func:`status`
      Read SQLite status, uses ``sqlite3_status`` internally.

.. data:: C_SQLITE_STATUS_MEMORY_USED
          C_SQLITE_STATUS_PAGECACHE_USED
          C_SQLITE_STATUS_PAGECACHE_OVERFLOW
          C_SQLITE_STATUS_SCRATCH_USED
          C_SQLITE_STATUS_SCRATCH_OVERFLOW
          C_SQLITE_STATUS_MALLOC_SIZE
          C_SQLITE_STATUS_PARSER_STACK
          C_SQLITE_STATUS_PAGECACHE_SIZE
          C_SQLITE_STATUS_SCRATCH_SIZE
          C_SQLITE_STATUS_MALLOC_COUNT

.. seealso::
   :meth:`Connection.status`
      Read SQLite database status, uses ``sqlite3_db_status`` internally.

.. data:: C_SQLITE_DBSTATUS_LOOKASIDE_USED
          C_SQLITE_DBSTATUS_CACHE_USED
          C_SQLITE_DBSTATUS_SCHEMA_USED
          C_SQLITE_DBSTATUS_STMT_USED
          C_SQLITE_DBSTATUS_LOOKASIDE_HIT
          C_SQLITE_DBSTATUS_LOOKASIDE_MISS_SIZE
          C_SQLITE_DBSTATUS_LOOKASIDE_MISS_FULL
          C_SQLITE_DBSTATUS_CACHE_HIT
          C_SQLITE_DBSTATUS_CACHE_MISS
          C_SQLITE_DBSTATUS_CACHE_WRITE
          C_SQLITE_DBSTATUS_DEFERRED_FKS

.. _sqlite-connection-flags:

Sqlite Connection Flags
^^^^^^^^^^^^^^^^^^^^^^^

.. seealso::
   :class:`Connection` and :func:`connect`
      Flags for controlling how connection is opened.

.. data:: C_SQLITE_OPEN_READONLY
          C_SQLITE_OPEN_READWRITE
          C_SQLITE_OPEN_CREATE
          C_SQLITE_OPEN_URI
          C_SQLITE_OPEN_MEMORY
          C_SQLITE_OPEN_NOMUTEX
          C_SQLITE_OPEN_FULLMUTEX
          C_SQLITE_OPEN_SHAREDCACHE
          C_SQLITE_OPEN_PRIVATECACHE

VFS-only Connection Flags
^^^^^^^^^^^^^^^^^^^^^^^^^

Support for these flags is dependent on the VFS providing an implementation.

.. data:: C_SQLITE_OPEN_DELETEONCLOSE
          C_SQLITE_OPEN_EXCLUSIVE
          C_SQLITE_OPEN_AUTOPROXY
          C_SQLITE_OPEN_WAL
          C_SQLITE_OPEN_MAIN_DB
          C_SQLITE_OPEN_TEMP_DB
          C_SQLITE_OPEN_TRANSIENT_DB
          C_SQLITE_OPEN_MAIN_JOURNAL
          C_SQLITE_OPEN_TEMP_JOURNAL
          C_SQLITE_OPEN_SUBJOURNAL
          C_SQLITE_OPEN_MASTER_JOURNAL

.. _authorizer-flags:

Authorizer Constants
^^^^^^^^^^^^^^^^^^^^

.. seealso::
   Setting an authorizer callback.
      :meth:`Connection.authorizer`

Return values (along with :data:`C_SQLITE_OK`) for authorizer callback.

.. data:: C_SQLITE_DENY
          C_SQLITE_IGNORE

Operations reported to authorizer callback.

.. data:: C_SQLITE_CREATE_INDEX
          C_SQLITE_CREATE_TABLE
          C_SQLITE_CREATE_TEMP_INDEX
          C_SQLITE_CREATE_TEMP_TABLE
          C_SQLITE_CREATE_TEMP_TRIGGER
          C_SQLITE_CREATE_TEMP_VIEW
          C_SQLITE_CREATE_TRIGGER
          C_SQLITE_CREATE_VIEW
          C_SQLITE_DELETE
          C_SQLITE_DROP_INDEX
          C_SQLITE_DROP_TABLE
          C_SQLITE_DROP_TEMP_INDEX
          C_SQLITE_DROP_TEMP_TABLE
          C_SQLITE_DROP_TEMP_TRIGGER
          C_SQLITE_DROP_TEMP_VIEW
          C_SQLITE_DROP_TRIGGER
          C_SQLITE_DROP_VIEW
          C_SQLITE_INSERT
          C_SQLITE_PRAGMA
          C_SQLITE_READ
          C_SQLITE_SELECT
          C_SQLITE_TRANSACTION
          C_SQLITE_UPDATE
          C_SQLITE_ATTACH
          C_SQLITE_DETACH
          C_SQLITE_ALTER_TABLE
          C_SQLITE_REINDEX
          C_SQLITE_ANALYZE
          C_SQLITE_CREATE_VTABLE
          C_SQLITE_DROP_VTABLE
          C_SQLITE_FUNCTION
          C_SQLITE_SAVEPOINT
          C_SQLITE_COPY
          C_SQLITE_RECURSIVE
