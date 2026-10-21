.. _migration:

Migrating from ``sqlite3``
==========================

.. _migration-connecting:

Connections
-----------

Before:

.. code-block:: python

   db = sqlite3.connect('app.db', timeout=2)

After using :func:`connect`:

.. code-block:: python

   db = cysqlite.connect('app.db', timeout=2)

Additional things you can do:

.. code-block:: python

   db = cysqlite.connect(
       'app.db',
       journal_mode='wal',
       pragmas={'cache_size': -64000, 'foreign_keys': 1})

   assert db.pragma('foreign_keys') == 1

Not supported:

* ``isolation_level`` / ``autocommit`` - cysqlite operates in autocommit mode.
  Transactions may be opened by issuing a ``BEGIN`` statement, using the
  :meth:`~Connection.begin` method, or preferably using the nestable
  :meth:`~Connection.atomic` context-manager/decorator.
* ``detect_types`` - column data-types are detected for the purposes of calling
  any user-defined data-type converters.
* ``check_same_thread`` - connections may be shared across threads.

Worth noting:

* :meth:`~Connection.close` raises :class:`OperationalError` if a transaction
  is open, while ``sqlite3`` discards the transaction. ``force=True`` rolls
  back and closes.
* URIs are handled transparently by cysqlite, e.g. ``file:/path.db?mode=ro``.

.. _migration-with:

Context manager
---------------

Before:

.. code-block:: python

   with sqlite3.connect('app.db') as db:
       # The first write opens a transaction.
       ...

   # stdlib commits on success or rolls back on failure. The connection
   # is left open.

After:

.. code-block:: python

   with cysqlite.connect('app.db') as db:
       # No transaction is automatically opened.
       ...

   # Connection is closed. It can be reopened via db.connect().

To emulate stdlib's behavior:

.. code-block:: python

   db = cysqlite.connect('app.db')
   with db.atomic():
       db.execute('insert into users (name) values (?)', ('alice',))

Executing queries
-----------------

:meth:`~Connection.execute`, :meth:`~Connection.executemany` and
:meth:`~Connection.executescript` exist on both the connection and the cursor,
with the same parameter styles:

.. code-block:: python

   db.execute('create table users (id integer primary key, name text unique)')
   db.executemany('insert into users (name) values (?)',
                  [('alice',), ('bob',)])

   curs = db.cursor()
   curs.execute('select id from users where name = ?', ('alice',)).fetchone()
   # (1,)
   curs.execute('select id from users where name = :name',
                {'name': 'bob'}).fetchone()
   # (2,)

Unlike stdlib, :meth:`~Connection.executescript` does not implicitly commit or
otherwise add its own transaction.

Parameter binding
^^^^^^^^^^^^^^^^^

Binding works the same, but cysqlite handles more types out-of-the-box:

* ``datetime``, ``date`` and ``time`` values bind as ISO-8601 text
* ``Decimal`` and ``Fraction`` bind a floating-point
* ``UUID`` values bind as text

.. code-block:: python

   db.execute_one('select ?, ?, ?, ?', (
       datetime.date(2026, 1, 2),
       datetime.time(3, 4, 5),
       Decimal('1.5'),
       uuid.UUID(int=1)))
   # ('2026-01-02', '03:04:05', 1.5, '00000000-0000-0000-0000-000000000001')

Reading results
---------------

Iteration, :meth:`~Cursor.fetchone` and :meth:`~Cursor.fetchall` work the same.
cysqlite also has additional helpers that return the first row or value
directly (:meth:`~Connection.execute_one` and :meth:`~Connection.execute_scalar`):

.. code-block:: python

   db.execute_one('select id, name from users where name = ?', ('bob',))
   # (2, 'bob')
   db.execute_scalar('select count(*) from users')
   # 2

:meth:`~Cursor.fetchmany` requires a size:

.. code-block:: python

   curs = db.execute('select name from users')
   curs.fetchmany(10)
   # [('alice',), ('bob',)]

Each :attr:`~Cursor.description` entry consists only of the column name, where
``sqlite3`` pads it to seven items with ``None``. Use :meth:`~Cursor.columns`
to retrieve the names as a list:

.. code-block:: python

   curs = db.execute('select id, name from users')
   curs.description
   # (('id',), ('name',))
   curs.columns()
   # ['id', 'name']

Replace ``sqlite3.Row`` with :class:`Row`:

.. code-block:: python

   db.row_factory = cysqlite.Row

   # Or:
   db = cysqlite.connect('app.db', row_factory=cysqlite.Row)

.. _migration-transactions:

Transactions
------------

cysqlite runs in autocommit mode and will not implicitly begin or commit
transactions. Statements outside a transaction commit as soon as they run.
See :ref:`transactions` for details.

Before:

.. code-block:: python

   # stdlib begins a transaction implicitly.
   db.execute('update accounts set balance = balance - 10 where id = 1')
   db.execute('update accounts set balance = balance + 10 where id = 2')
   db.commit()  # Without this, close() discards both updates.

After using :meth:`~Connection.atomic`:

.. code-block:: python

   # cysqlite has explicit transaction boundaries.
   with db.atomic():
       db.execute('update accounts set balance = balance - 10 where id = 1')
       db.execute('update accounts set balance = balance + 10 where id = 2')

   # Or:
   db.begin()
   db.execute('update accounts set balance = balance - 10 where id = 1')
   db.execute('update accounts set balance = balance + 10 where id = 2')
   db.commit()

Additional things you can do:

.. code-block:: python

   with db.atomic(lock='IMMEDIATE'):  # Replaces isolation_level.
       db.execute('insert into users (name) values (?)', ('carol',))
       try:
           with db.atomic():  # Nested blocks use savepoints.
               db.execute('insert into users (name) values (?)', ('alice',))
       except cysqlite.IntegrityError:
           pass  # Only the inner block is rolled back.

Worth noting:

* :meth:`~Connection.commit` and :meth:`~Connection.rollback` raise
  :class:`OperationalError` when no transaction is open, where ``sqlite3``
  does nothing.
* :meth:`~Connection.autocommit` is a method, not the attribute ``sqlite3``
  added in Python 3.12.

.. _migration-types:

Adapters and converters
-----------------------

Adapters and converters are registered on the connection, not globally on the
module. Converters match the declared column type, as described in
:ref:`sqlite-converters`.

Before:

.. code-block:: python

   sqlite3.register_adapter(dict, json.dumps)
   sqlite3.register_converter('json', json.loads)
   db = sqlite3.connect('app.db', detect_types=sqlite3.PARSE_DECLTYPES)

After:

.. code-block:: python

   db = cysqlite.connect('app.db')
   db.register_adapter(dict, json.dumps)
   db.register_converter('json', json.loads)

Not supported:

* ``PARSE_COLNAMES`` - column-alias type hints have no equivalent.
* ``__conform__()`` - register an adapter for the class instead.

Errors
------

DB-API exception hierarchy is preserved. Constraint violations and I/O errors
raise a subclass based on the SQLite error code.

Before:

.. code-block:: python

   try:
       db.execute('insert into users (name) values (?)', ('alice',))
   except sqlite3.IntegrityError as exc:
       if exc.sqlite_errorname != 'SQLITE_CONSTRAINT_UNIQUE':
           raise

After:

.. code-block:: python

   try:
       db.execute('insert into users (name) values (?)', ('alice',))
   except cysqlite.UniqueIntegrityError:  # Subclass of IntegrityError.
       pass

Not supported:

* ``sqlite_errorname`` - :attr:`~SqliteError.sqlite_errorcode` stores the
  extended result code, as in ``sqlite3``.

.. _migration-udf:

User-defined functions
----------------------

The callable comes first, ``name`` defaults to its ``__name__`` and ``nargs``
defaults to -1 (any number of arguments). The same goes for aggregates, window
functions and collations.

Before:

.. code-block:: python

   db.create_function('title_case', 1, title_case)
   db.create_aggregate('product', 1, Product)
   db.create_window_function('mysum', 1, MySum)
   db.create_collation('reverse', collate_reverse)

After:

.. code-block:: python

   db.create_function(title_case)
   db.create_aggregate(Product)
   db.create_window_function(MySum, 'mysum')
   db.create_collation(collate_reverse, 'reverse')

Worth noting:

* Functions are registered with ``deterministic=True`` by default, where
  ``sqlite3`` uses ``False``. Pass ``deterministic=False`` for a function
  whose result can change between calls with the same arguments.
* ``sqlite3.enable_callback_tracebacks()`` becomes the per-connection
  :attr:`~Connection.print_callback_tracebacks` attribute.
* The exception a callback raised is chained as the ``__cause__`` of the
  error the query raises.

Authorizer, progress and trace
------------------------------

Before:

.. code-block:: python

   db.set_authorizer(authorizer)
   db.set_progress_handler(handler, 1000)
   db.set_trace_callback(print)

After:

.. code-block:: python

   db.authorizer(authorizer)
   db.progress(handler, 1000)
   db.trace(lambda event, sid, sql, ns: print(sql))

The trace callback receives ``(event, sid, sql, ns)`` instead of ``(sql)``. By
default it runs when each statement finishes, with the run time in
nanoseconds. See :meth:`~Connection.trace` for the other events.

BLOBs
-----

Before:

.. code-block:: python

   blob = db.blobopen('files', 'data', 1)

After using :meth:`~Connection.blob_open`:

.. code-block:: python

   blob = db.blob_open('files', 'data', 1)

Additional things you can do:

* :class:`Blob` implements ``io.RawIOBase``.
* :meth:`~Blob.reopen` moves the blob to another row.

Backup and serialization
------------------------

:meth:`~Connection.serialize` and :meth:`~Connection.deserialize` work the
same. The :meth:`~Connection.backup` progress callback takes different
arguments.

Before:

.. code-block:: python

   db.backup(dest, progress=lambda status, remaining, total: ...)

After:

.. code-block:: python

   db.backup(dest, progress=lambda remaining, total, done: ...)

Not supported:

* The ``sleep`` argument to ``backup()``.
* ``iterdump()``.

Additional things you can do:

.. code-block:: python

   db.backup_to_file('copy.db')

Extensions, limits and configuration
------------------------------------

:meth:`~Connection.load_extension` works without calling
:meth:`~Connection.enable_load_extension` first. ``getlimit()`` and
``setlimit()`` work the same.

Before:

.. code-block:: python

   db.setconfig(sqlite3.SQLITE_DBCONFIG_ENABLE_FKEY, True)
   db.getconfig(sqlite3.SQLITE_DBCONFIG_ENABLE_FKEY)

After using :meth:`~Connection.db_config`:

.. code-block:: python

   db.db_config(cysqlite.SQLITE_DBCONFIG_ENABLE_FKEY, 1)
   db.db_config(cysqlite.SQLITE_DBCONFIG_ENABLE_FKEY)

Additional things you can do:

* Pass ``extensions=False`` to :func:`connect` to disable extension loading.
* Common settings have their own methods, such as
  :meth:`~Connection.set_foreign_keys_enabled`.

Additional features
-------------------

Reconnecting
^^^^^^^^^^^^

:meth:`~Connection.connect` reopens a closed connection. Any functions,
aggregates, collations or table functions registered on it are re-registered
automatically:

.. code-block:: python

   db.create_function(title_case)
   db.close()
   db.connect()
   db.execute_scalar("select title_case('hello')")
   # 'Hello'

Table-valued functions
^^^^^^^^^^^^^^^^^^^^^^

A generator can be queried as a table. Subclass :class:`TableFunction` for
writable tables. See :ref:`user-defined-functions`:

.. code-block:: python

   @db.table_function(columns=['value'])
   def series(start, stop, step=1):
       for i in range(start, stop, step):
           yield (i,)

   db.execute('select value from series(0, 10, 3)').fetchall()
   # [(0,), (3,), (6,), (9,)]

Commit, rollback and update hooks
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

:meth:`~Connection.commit_hook` and :meth:`~Connection.rollback_hook` run at
transaction boundaries. :meth:`~Connection.update_hook` runs for each changed
row:

.. code-block:: python

   changes = []

   def on_update(op, dbname, table, rowid):
       changes.append((op, table, rowid))

   db.update_hook(on_update)
   db.execute('insert into users (name) values (?)', ('carol',))
   changes
   # [('INSERT', 'users', 3)]

Busy handler
^^^^^^^^^^^^

:meth:`~Connection.set_busy_handler` replaces the busy timeout with a handler
that retries more often, with jitter:

.. code-block:: python

   db.set_busy_handler(timeout=10)

Introspection
^^^^^^^^^^^^^

cysqlite provides a number of helpers for introspecting the schema:

* :meth:`~Connection.get_tables`
* :meth:`~Connection.get_views`
* :meth:`~Connection.get_indexes`
* :meth:`~Connection.get_columns`
* :meth:`~Connection.get_primary_keys`
* :meth:`~Connection.get_foreign_keys`
* :meth:`~Connection.table_column_metadata`
* :meth:`~Connection.database_list`

.. code-block:: python

   db.get_tables()
   # ['users']
   db.get_primary_keys('users')
   # ['id']

Maintenance
^^^^^^^^^^^

* :meth:`~Connection.attach` and :meth:`~Connection.detach` manage attached
  databases.
* :meth:`~Connection.checkpoint` and :meth:`~Connection.set_autocheckpoint`
  control the WAL.
* :meth:`~Connection.optimize` runs ``PRAGMA optimize``.

.. code-block:: python

   db.attach('archive.db', 'archive')
   db.get_tables('archive')
   # ['users_2020']
   db.detach('archive')

   db.checkpoint(truncate=True)
   # (0, 0)
   db.optimize()

Diagnostics
^^^^^^^^^^^

* :func:`status` and :meth:`Connection.status` report SQLite's memory and
  cache counters.
* :func:`compile_option` and :func:`vfs_list` describe the SQLite build.

.. code-block:: python

   current, highwater = cysqlite.status(cysqlite.SQLITE_STATUS_MEMORY_USED)
   current, highwater = db.status(cysqlite.SQLITE_DBSTATUS_CACHE_USED)
   cysqlite.compile_option('ENABLE_FTS5')
   # 1
   'unix' in cysqlite.vfs_list()
   # True

Slow query log
^^^^^^^^^^^^^^

:func:`cysqlite.utils.slow_query_log` logs statements that run longer than a
threshold:

.. code-block:: python

   from cysqlite.utils import slow_query_log

   slow_query_log(db, threshold_ms=100)

Async
^^^^^

:mod:`cysqlite.aio` runs queries on a worker thread for use with asyncio. See
:ref:`aio` for its caveats:

.. code-block:: python

   from cysqlite.aio import connect

   async def main():
       async with connect('app.db') as db:
           return await db.execute_scalar('select count(*) from users')

   asyncio.run(main())
   # 2

Builds
^^^^^^

cysqlite can bundle its own SQLite, or build against SQLCipher or SQLite3
Multiple Ciphers. See :ref:`installation`.
