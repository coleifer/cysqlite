.. _migration:

Migrating from ``sqlite3``
==========================

cysqlite follows the stdlib ``sqlite3`` API closely. For the design rationale,
see :ref:`sqlite-notes`.

.. _migration-connecting:

Connecting
----------

:func:`connect` takes the same path, ``timeout`` and ``uri`` arguments.

.. code-block:: python

   db = cysqlite.connect('app.db', timeout=10)

   ro = cysqlite.connect('file:app.db?mode=ro')
   ro.execute('delete from users')  # Raises ReadOnlyError.

Use ``pragmas`` to configure the connection when it opens. They are applied
again each time it reopens. ``journal_mode`` is a shortcut for the most common
one:

.. code-block:: python

   db = cysqlite.connect('app.db', journal_mode='wal',
                         pragmas={'cache_size': -64000, 'foreign_keys': 1})
   db.pragma('foreign_keys')
   # 1

The following parameters are not used and will raise a :class:`TypeError`:

* ``isolation_level`` / ``autocommit`` - cysqlite operates in autocommit mode.
  Transactions may be opened by issuing a ``BEGIN`` statement, using the
  :meth:`~Connection.begin` method, or preferably using the nestable
  :meth:`~Connection.atomic` context-manager/decorator.
* ``detect_types`` - column data-types are detected for the purposes of calling
  any user-defined converters.
* ``check_same_thread`` - connections may be shared across threads.

:meth:`~Connection.close` raises :class:`OperationalError` while a transaction
is open, where ``sqlite3`` discards the transaction. ``force=True`` rolls back
and closes:

.. code-block:: python

   db.begin()
   db.close()  # Raises OperationalError.
   db.close(force=True)

.. _migration-with:

Context manager and decorator
-----------------------------

``with db:`` manages the connection and does not implicitly open a transaction.
The connection is opened and when the wrapped block exits, any open
transaction is rolled-back and the connection is closed (nested blocks are
no-ops).

In ``sqlite3``, ``with conn:`` commits on success, rolls back on error and
leaves the connection open. In cysqlite use :meth:`~Connection.atomic` instead.

.. code-block:: python

   db = cysqlite.connect('app.db')

   with db:
       # Committed immediately.
       db.execute('insert into users (name) values (?)', ('carol',))

       # Rolled back when the block exits.
       db.begin()
       db.execute('insert into users (name) values (?)', ('dave',))

   db.is_closed()
   # True

   with db:  # Reopens the connection.
       names = db.execute('select name from users where name in (?, ?)',
                          ('carol', 'dave')).fetchall()

   names
   # [('carol',)]

Closing the connection invalidates its cursors, so fetch results inside the
block:

.. code-block:: python

   with db:
       curs = db.execute('select name from users')

   curs.fetchall()  # Raises OperationalError.

``@db`` runs each call to the decorated function inside ``with db:``, so
decorated functions can call each other. The connection closes when the
outermost call returns:

.. code-block:: python

   db = cysqlite.connect('app.db', autoconnect=False)

   @db
   def count_users():
       return db.execute_scalar('select count(*) from users')

   @db
   def report():
       count_users()  # Connection stays open.
       return db.is_closed()

   report()
   # False
   db.is_closed()
   # True

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

:meth:`~Connection.executescript` does not implicitly commit or otherwise add
its own transaction. Wrap calls to :meth:`~Connection.executescript` in
:meth:`~Connection.atomic` to apply all of it or none of it. ``sqlite3`` would
keep the first two statements below, even inside ``with conn:``:

.. code-block:: python

   db = cysqlite.connect(':memory:')

   script = '''
       create table accounts (id integer primary key, balance int);
       insert into accounts (balance) values (100);
       insert into MISSING (x) values (1);
   '''
   with db.atomic():
       db.executescript(script)  # Raises OperationalError.

   db.get_tables()
   # []

Parameter binding
^^^^^^^^^^^^^^^^^

``datetime`` and ``date`` values bind as ISO-8601 text without a deprecation
warning. ``time``, ``Decimal``, ``Fraction`` and ``UUID`` values also bind,
where ``sqlite3`` raises an error. Types with no mapping raise
:class:`TypeError` rather than :class:`ProgrammingError`. The full mapping is
described in :ref:`sqlite-notes`.

.. code-block:: python

   db.execute_one('select ?, ?, ?, ?', (
       datetime.date(2026, 1, 2),
       datetime.time(3, 4, 5),
       Decimal('1.5'),
       uuid.UUID(int=1)))
   # ('2026-01-02', '03:04:05', 1.5, '00000000-0000-0000-0000-000000000001')

   db.execute('select ?', ([1, 2],))  # Raises TypeError.

Reading results
---------------

Iteration, ``fetchone()`` and ``fetchall()`` work the same as ``sqlite3``.
:meth:`~Connection.execute_one` and :meth:`~Connection.execute_scalar` are
helpers that return the first row or the first value directly:

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

Each :attr:`~Cursor.description` entry holds only the column name, where
``sqlite3`` pads it to seven items with ``None``. Code that reads ``d[0]`` is
unaffected. Use :meth:`~Cursor.columns` to retrieve the names as a list:

.. code-block:: python

   curs = db.execute('select id, name from users')
   curs.description
   # (('id',), ('name',))
   curs.columns()
   # ['id', 'name']
   curs.conn is db
   # True

:class:`Row` supports index and name lookup and ``keys()`` like
``sqlite3.Row``, plus attribute access, dict methods and :meth:`~Row.as_dict`.
Lookup by name is case-sensitive:

.. code-block:: python

   db.row_factory = cysqlite.Row
   row = db.execute_one('select id, name from users')
   row['name'], row.name, row[1]
   # ('alice', 'alice', 'alice')
   row.as_dict()
   # {'id': 1, 'name': 'alice'}
   row == (1, 'alice')
   # True
   row['NAME']  # Raises KeyError.

:func:`dict_factory` is built in. A row factory can also be passed to a single
:meth:`~Connection.execute` call:

.. code-block:: python

   db.execute('select id, name from users',
              row_factory=cysqlite.dict_factory).fetchall()
   # [{'id': 1, 'name': 'alice'}, {'id': 2, 'name': 'bob'}]

There is no ``text_factory``. TEXT decodes as UTF-8, and invalid bytes raise
:class:`UnicodeDecodeError`. Cast to BLOB to read the raw bytes:

.. code-block:: python

   db.execute_scalar("select cast(x'ff' as text)")  # Raises UnicodeDecodeError.
   db.execute_scalar("select cast(x'ff' as blob)")
   # b'\xff'

.. _migration-counts:

Row counts and inserted IDs
---------------------------

:attr:`~Cursor.rowcount` matches ``sqlite3`` for INSERT, UPDATE, DELETE and
``executemany()``, and :attr:`~Cursor.lastrowid` matches after INSERT.

On the connection, :meth:`~Connection.total_changes` is a method, where
``sqlite3`` has an attribute. :meth:`~Connection.changes` returns the rows
changed by the most recent statement and :meth:`~Connection.last_insert_rowid`
the most recent inserted rowid:

.. code-block:: python

   db.total_changes()
   # 0

   db.execute('insert into users (name) values (?)', ('alice',))
   db.changes(), db.total_changes(), db.last_insert_rowid()
   # (1, 1, 1)

.. _migration-transactions:

Transactions
------------

cysqlite never issues ``BEGIN`` on its own. A statement outside a transaction
commits as soon as it runs. See :ref:`transactions` for the reasons.

.. code-block:: python

   # sqlite3
   db = sqlite3.connect('app.db')
   db.execute('insert into users (name) values (?)', ('carol',))
   db.in_transaction
   # True
   db.close()

   db = sqlite3.connect('app.db')
   db.execute('select count(*) from users where name = ?', ('carol',)).fetchone()
   # (0,)

.. code-block:: python

   db = cysqlite.connect('app.db')
   db.execute('insert into users (name) values (?)', ('carol',))
   db.in_transaction
   # False
   db.close()

   db = cysqlite.connect('app.db')
   db.execute_scalar('select count(*) from users where name = ?', ('carol',))
   # 1

Replace ``commit()`` and ``with conn:`` with :meth:`~Connection.atomic`. It
commits when the block exits and rolls back if the block raises:

.. code-block:: python

   # sqlite3
   db.execute('update accounts set balance = balance - 10 where id = 1')
   db.execute('update accounts set balance = balance + 10 where id = 2')
   db.commit()

   with db:
       db.execute('update accounts set balance = balance - 10 where id = 1')
       db.execute('update accounts set balance = balance + 10 where id = 2')

.. code-block:: python

   # cysqlite
   with db.atomic():
       db.execute('update accounts set balance = balance - 10 where id = 1')
       db.execute('update accounts set balance = balance + 10 where id = 2')

The lock type moves from the connection to the transaction:

.. code-block:: python

   # sqlite3
   db = sqlite3.connect('app.db', isolation_level='IMMEDIATE')

.. code-block:: python

   # cysqlite
   with db.atomic(lock='IMMEDIATE'):
       db.execute('update accounts set balance = balance - 10 where id = 1')

In ``sqlite3``, nested ``with conn:`` blocks share one transaction, so the
inner block's exit commits or rolls back the outer block's writes too. Nested
:meth:`~Connection.atomic` blocks use savepoints, so a failure inside the
inner block rolls back only that block:

.. code-block:: python

   # sqlite3
   with db:
       db.execute('insert into users (name) values (?)', ('carol',))
       db.execute('savepoint sp')
       try:
           db.execute('insert into users (name) values (?)', ('alice',))
       except sqlite3.IntegrityError:
           db.execute('rollback to sp')
       db.execute('release sp')

   db.execute('select count(*) from users where name = ?', ('carol',)).fetchone()
   # (1,)

.. code-block:: python

   # cysqlite
   with db.atomic():
       db.execute('insert into users (name) values (?)', ('carol',))
       try:
           with db.atomic():
               db.execute('insert into users (name) values (?)', ('alice',))
       except cysqlite.IntegrityError:
           pass

   db.execute_scalar('select count(*) from users where name = ?', ('carol',))
   # 1

:meth:`~Connection.commit` and :meth:`~Connection.rollback` raise
:class:`OperationalError` when no transaction is open.

:attr:`~Connection.in_transaction` works as in ``sqlite3``.
:meth:`~Connection.autocommit` is a method, not the attribute ``sqlite3``
added in Python 3.12.

:meth:`~Connection.begin` opens a transaction explicitly:

.. code-block:: python

   # cysqlite
   db.in_transaction, db.autocommit()
   # (False, True)
   db.begin()
   db.in_transaction, db.autocommit()
   # (True, False)
   db.rollback()

See :ref:`transactions-recommended` for the decorator form, flat transactions
and explicit savepoints.

.. _migration-types:

Adapters and converters
-----------------------

Adapters and converters are registered on the connection, not the module.
There is no ``detect_types``. Converters always match the declared column
type, as described in :ref:`sqlite-converters`, and column-alias type hints
(``PARSE_COLNAMES``) have no equivalent:

.. code-block:: python

   # sqlite3
   sqlite3.register_adapter(dict, json.dumps)
   sqlite3.register_converter('json', json.loads)
   db = sqlite3.connect('app.db', detect_types=sqlite3.PARSE_DECLTYPES)

.. code-block:: python

   db = cysqlite.connect('app.db')
   db.register_adapter(dict, json.dumps)
   db.register_converter('json', json.loads)

   db.execute('create table events (data json)')
   db.execute('insert into events (data) values (?)', ({'k': 'v'},))
   db.execute_scalar('select data from events')
   # {'k': 'v'}

Objects with a ``__conform__()`` method need a registered adapter instead:

.. code-block:: python

   # sqlite3
   class Point:
       def __init__(self, x, y):
           self.x, self.y = x, y

       def __conform__(self, protocol):
           return f'{self.x};{self.y}'

   db.execute('select ?', (Point(1, 2),)).fetchone()
   # ('1;2',)

.. code-block:: python

   # cysqlite
   db.register_adapter(Point, lambda p: f'{p.x};{p.y}')
   db.execute_one('select ?', (Point(1, 2),))
   # ('1;2',)

Errors
------

The DB-API exception classes keep their names and are importable from
``cysqlite``. Constraint violations and I/O errors raise a subclass based on
the SQLite error code:

.. code-block:: python

   # sqlite3
   try:
       db.execute('insert into users (name) values (?)', ('alice',))
   except sqlite3.IntegrityError as exc:
       if exc.sqlite_errorname != 'SQLITE_CONSTRAINT_UNIQUE':
           raise

.. code-block:: python

   from cysqlite import UniqueIntegrityError

   try:
       db.execute('insert into users (name) values (?)', ('alice',))
   except UniqueIntegrityError:
       pass

:attr:`~SqliteError.sqlite_errorcode` holds the extended result code, as in
``sqlite3``. There is no ``sqlite_errorname``. Both codes also appear in the
message, along with the SQL:

.. code-block:: python

   try:
       db.execute('insert into users (name) values (?)', ('alice',))
   except cysqlite.IntegrityError as exc:
       code = exc.sqlite_errorcode

   code
   # 2067
   db.execute('insert into users (name) values (?)', ('alice',))
   # UniqueIntegrityError: error executing query: [insert into users (name)
   # values (?)] UNIQUE constraint failed: users.name (code=19, ext=2067)

Passing the wrong number of parameters or using a closed connection raises
:class:`OperationalError`, where ``sqlite3`` raises
:class:`ProgrammingError`.

.. _migration-udf:

User-defined functions
----------------------

The callable comes first, ``name`` defaults to its ``__name__`` and ``nargs``
defaults to -1 (any number of arguments). The same goes for aggregates, window
functions and collations:

.. code-block:: python

   # sqlite3
   db.create_function('title_case', 1, title_case)
   db.create_aggregate('product', 1, Product)
   db.create_window_function('mysum', 1, MySum)
   db.create_collation('reverse', collate_reverse)

.. code-block:: python

   # cysqlite
   db.create_function(title_case)
   db.create_aggregate(Product)
   db.create_window_function(MySum, 'mysum')
   db.create_collation(collate_reverse, 'reverse')

   db.execute_scalar("select title_case('hello world')")
   # 'Hello World'
   db.execute_scalar('select product(id) from users')
   # 2

Functions are registered with ``deterministic=True`` by default, where
``sqlite3`` uses ``False``. Pass ``deterministic=False`` for a function whose
result can change between calls with the same arguments:

.. code-block:: python

   db.create_function(time.time, 'now', deterministic=False)

``sqlite3.enable_callback_tracebacks()`` becomes the per-connection
:attr:`~Connection.print_callback_tracebacks` attribute. The exception a
callback raised is also chained as the ``__cause__`` of the error the query
raises:

.. code-block:: python

   db.create_function(int, 'parse_int')
   db.print_callback_tracebacks = True

   try:
       db.execute("select parse_int('x')")
   except cysqlite.OperationalError as exc:
       cause = exc.__cause__

   cause
   # ValueError("invalid literal for int() with base 10: 'x'")

Authorizer, progress and trace
------------------------------

The callback setters are renamed:

.. code-block:: python

   # sqlite3
   db.set_authorizer(authorizer)
   db.set_progress_handler(handler, 1000)
   db.set_trace_callback(print)

.. code-block:: python

   # cysqlite
   db.authorizer(authorizer)
   db.progress(handler, 1000)
   db.trace(lambda event, sid, sql, ns: print(sql))

The trace callback receives ``(event, sid, sql, ns)`` instead of ``(sql)``. By
default it runs when each statement finishes, with the run time in
nanoseconds. See :meth:`~Connection.trace` for the other events.

BLOBs
-----

:meth:`~Connection.blob_open` replaces ``blobopen()`` and takes the same
arguments. :class:`Blob` implements ``io.RawIOBase``, and
:meth:`~Blob.reopen` moves it to another row:

.. code-block:: python

   blob = db.blob_open('files', 'data', 2)
   blob.readline()
   # b'line 1\n'
   blob.reopen(1)
   len(blob)
   # 64
   blob.close()

Backup and serialization
------------------------

:meth:`~Connection.backup` works as in ``sqlite3``, but the progress callback
receives ``(remaining, page_count, done)`` instead of
``(status, remaining, total)``, and there is no ``sleep`` argument:

.. code-block:: python

   progress = []
   db.backup(cysqlite.connect('backup.db'), pages=1,
             progress=lambda *args: progress.append(args))
   progress
   # [(2, 3, False), (1, 3, False), (0, 3, True)]

:meth:`~Connection.serialize` and :meth:`~Connection.deserialize` are
unchanged. There is no ``iterdump()``. To copy a database to a file, use
:meth:`~Connection.backup_to_file`:

.. code-block:: python

   db.backup_to_file('copy.db')

Extensions, limits and configuration
------------------------------------

:meth:`~Connection.load_extension` works without calling
:meth:`~Connection.enable_load_extension` first. Pass ``extensions=False`` to
:func:`connect` to disable extension loading:

.. code-block:: python

   db.load_extension('./vec0')

   db = cysqlite.connect(':memory:', extensions=False)
   db.load_extension('./vec0')  # Raises OperationalError.

``getlimit()`` and ``setlimit()`` are unchanged. ``setconfig()`` and
``getconfig()`` become :meth:`~Connection.db_config`, which returns the
current value. Common settings also have their own methods:

.. code-block:: python

   # sqlite3
   db.setconfig(sqlite3.SQLITE_DBCONFIG_ENABLE_FKEY, True)
   db.getconfig(sqlite3.SQLITE_DBCONFIG_ENABLE_FKEY)
   # True

.. code-block:: python

   db.db_config(cysqlite.SQLITE_DBCONFIG_ENABLE_FKEY, 1)
   # 1
   db.set_foreign_keys_enabled(1)
   db.get_foreign_keys_enabled()
   # 1

.. _migration-threads:

Threads
-------

There is no ``check_same_thread``, so any thread can use a connection.
Threads that share a connection also share its transaction. Give each thread
its own connection, or use :class:`cysqlite.utils.Pool`, which provides
read-only connections and serializes access to a single writer:

.. code-block:: python

   from cysqlite.utils import Pool

   pool = Pool('app.db')

   with pool.writer() as conn:
       conn.execute('insert into users (name) values (?)', ('carol',))

   with pool.reader() as conn:
       conn.execute_scalar('select count(*) from users')

Additional features
-------------------

Reconnecting
^^^^^^^^^^^^

:meth:`~Connection.connect` reopens a closed connection. Functions,
aggregates, collations and table functions registered on it are registered
again:

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

Built-in functions
^^^^^^^^^^^^^^^^^^

cysqlite provides these SQL functions:

* :func:`levenshtein_dist`
* :func:`damerau_levenshtein_dist`
* :class:`median`
* :func:`rank_bm25`
* :func:`rank_lucene`

Register them like any other function:

.. code-block:: python

   db.create_function(cysqlite.levenshtein_dist)
   db.create_aggregate(cysqlite.median)

   db.execute_scalar("select levenshtein_dist('kitten', 'sitting')")
   # 3
   db.execute_scalar('select median(salary) from employees')
   # 110.0

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
