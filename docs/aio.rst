.. _aio:


Async I/O
=========

.. module:: cysqlite.aio

The ``cysqlite.aio`` module provides an experimental asyncio interface to
cysqlite. Queries and other blocking methods get sent to a worker thread.

SQLite operates on local disk storage, so queries typically execute extremely
quickly (microseconds / few milliseconds). The cost of dispatching to a
background thread and wrapping in coroutines increases the latency per query.
For every query executed, a closure must be created, a future allocated, a
queue written-to, a loop ``call_soon_threadsafe()`` issued, and two context
switches made. This is the case with cysqlite and other drivers like `aiosqlite <https://github.com/omnilib/aiosqlite/blob/main/aiosqlite/core.py>`__.

If your SQLite workload is heavy enough that avoiding blocking the event-loop
is an issue, SQLite may not be a good fit. SQLite only allows one writer at a
time, so while using an async wrapper may keep things responsive while waiting
to obtain the write lock, writes will not occur "faster", the bottleneck has
merely been moved. Conversely, if you don't have that much load, the async
wrapper adds complexity and overhead for no measurable benefit.

It's like a super fancy restaurant that has only one table. When using SQLite,
any thread or task that needs to write has to wait in the lobby for the hostess
to seat them at the one available table. The ``aio`` implementation here
changes things so that now there are plenty of tables, but only one set of
plates. Everybody can sit down, but they are still waiting, since the plates
can only be at one table at any given time.

Additionally, if multiple coroutines share a single async connection, transaction
state can get interleaved between tasks, leading to data corruption. Transactions
and savepoints **will** end up getting interleaved if your connection is used by
multiple tasks and you have any concurrency. aiosqlite suffers from this problem
as well (since 2018!).

The bottom-line is that the best ways to avoid blowing off your foot:

* Use an :class:`AsyncConnection` **per task**, or
* Use the :class:`Pool` and check-out the single, dedicated writer connection
  whenever you need a transaction.

Example pool usage:

.. code-block:: python

   # Pool serializes access to the writer, so transactions are safe.
   pool = Pool('app.db')

   async def task_a(pool):
       async with pool.writer() as db:
           async with db.atomic() as tx:
               await db.execute('insert into ...')
               await asyncio.sleep(0)

   async def task_b(pool):
       async with pool.writer() as db:
           async with db.atomic() as tx:
               await db.execute('insert into ...')
               await tx.rollback()

Module
------

.. function:: connect(database, **kwargs)

   Open an :class:`AsyncConnection` to the database. Arbitrary keyword
   arguments are passed to the underlying synchronous ``cysqlite.connect()``.

   Must be called from within a running asyncio event loop.

   :param database: database filename or ``':memory:'``.
   :type database: str, ``pathlib.Path``
   :param kwargs: passed to ``cysqlite.connect()``, e.g. ``timeout``, ``pragmas``.
   :return: async connection wrapping a synchronous :class:`Connection`.
   :rtype: :class:`AsyncConnection`

   Example:

   .. code-block:: python

      import asyncio
      from cysqlite.aio import connect

      async def main():
          db = connect(':memory:')

          await db.execute('create table kv (key text, value text)')
          await db.execute('insert into kv (key, value) values (?, ?)',
                           ('hello', 'world'))

          row = await db.execute_one('select * from kv')
          print(row)  # ('hello', 'world')

          await db.close()

      asyncio.run(main())

   The connection can also be used as an async context-manager:

   .. code-block:: python

      async with connect('app.db', pragmas={'journal_mode': 'wal'}) as db:
          await db.execute('create table if not exists kv ("key", "value")')
          await db.execute('insert into kv values (?, ?)', ('hello', 'asyncio'))

      # Connection is closed.


AsyncConnection
---------------

.. class:: AsyncConnection(conn, loop)

   Async wrapper around synchronous :class:`Connection`, created
   by :func:`connect`.

   :param Connection conn: synchronous cysqlite connection.
   :param loop: the running asyncio event loop.

   Every :class:`AsyncConnection` has a dedicated background ``threading.Thread``
   from which it pulls queries or other blocking operations. All SQLite calls for
   a given connection are serialized through that thread.

   .. attribute:: conn

      The underlying synchronous :class:`Connection`.

   .. method:: execute(sql, params=None)
      :async:

      Execute the given *sql* and return an :class:`AsyncCursor`.

      :param str sql: SQL query to execute.
      :param params: parameters for query (optional).
      :type params: tuple, list, dict, or ``None``
      :return: cursor wrapping the result set.
      :rtype: :class:`AsyncCursor`

      If the awaiting coroutine is cancelled while the query is running,
      :meth:`~Connection.interrupt` is called on the underlying
      connection to abort it. A query still waiting in the queue is skipped.

      Example:

      .. code-block:: python

         curs = await db.execute('select * from users where active = ?', (1,))
         for row in await curs.fetchall():
             print(row)

   .. method:: executemany(sql, seq_of_params)
      :async:

      Execute the given *sql* repeatedly for each parameter group.

      Queries executed by :meth:`~AsyncConnection.executemany` must not return
      any result rows, or this will result in an :class:`OperationalError`.

      :param str sql: SQL query to execute.
      :param seq_of_params: iterable of parameters.
      :type seq_of_params: sequence of tuple, list, sequence, dict, or ``None``.
      :return: cursor.
      :rtype: :class:`AsyncCursor`

      Example:

      .. code-block:: python

         await db.execute('create table kv ("id" integer primary key, "key", "value")')

         curs = await db.executemany('insert into kv (key, value) values (?, ?)',
                                     [('k1', 'v1'), ('k2', 'v2'), ('k3', 'v3')])
         print(curs.lastrowid)  # 3.
         print(curs.rowcount)  # 3.

         curs = await db.executemany('insert into kv (key, value) values (:k, :v)',
                                    [{'k': 'k4', 'v': 'v4'}, {'k': 'k5', 'v': 'v5'}])
         print(curs.lastrowid)  # 5.
         print(curs.rowcount)  # 2.

   .. method:: executescript(sql)
      :async:

      Execute one or more SQL statements separated by semicolons.

      :param str sql: one or more SQL statements.
      :return: cursor.
      :rtype: :class:`AsyncCursor`

      Example:

      .. code-block:: python

         await db.executescript("""
             begin;
             create table users (
                id integer not null primary key,
                name text not null,
                email text not null);
             create index users_email ON users (email);

             create table tweets (
                id integer not null primary key,
                content text not null,
                user_id integer not null references users (id),
                timestamp integer not null);

             commit;
         """)

   .. method:: execute_one(sql, params=None)
      :async:

      Execute a query and return the first row, or ``None``.

      :param str sql: SQL query.
      :param params: parameters (optional).
      :return: first row or ``None``.
      :rtype: tuple, :class:`Row`, or ``None``

   .. method:: execute_scalar(sql, params=None)
      :async:

      Execute a query and return the first column of the first row, or ``None``.

      :param str sql: SQL query.
      :param params: parameters (optional).
      :return: scalar value or ``None``.

      Example:

      .. code-block:: python

         count = await db.execute_scalar('select count(*) from users')

   .. method:: begin(lock=None)
      :async:

      Begin a transaction.

      If a transaction is already active, raises :class:`OperationalError`.

      :param str lock: type of SQLite lock to acquire, ``DEFERRED`` (default),
         ``IMMEDIATE``, or ``EXCLUSIVE``.

   .. method:: commit()
      :async:

      Commit the current transaction.

      If no transaction is active, raises :class:`OperationalError`.

   .. method:: rollback()
      :async:

      Roll back the current transaction.

      If no transaction is active, raises :class:`OperationalError`.

   .. method:: close()
      :async:

      Close the underlying database connection and shut down the background
      thread. Waits up to 5 seconds for the thread to exit.

      :raises RuntimeError: if the background thread does not terminate.

      After ``close()``, further operations raise :class:`OperationalError`.
      Calling ``close()`` on an already-closed connection returns ``False``.

   .. property:: in_transaction

      Whether a transaction is currently active.

      :rtype: bool

   .. method:: atomic(lock=None)

      Create an async context-manager which runs queries in a transaction
      (or savepoint when nested).

      Calls to :meth:`~AsyncConnection.atomic` can be nested.

      :param str lock: lock type: ``DEFERRED``, ``IMMEDIATE``, or ``EXCLUSIVE``.
      :return: :class:`AsyncAtomic`

      If you share your :class:`AsyncConnection` across tasks, transactions and
      savepoints **will** end up getting interleaved if you have any concurrency,
      and this will certainly cause problems. The best way to avoid bugs from
      interleaved transactions is to:

      * Use an :class:`AsyncConnection` **per task**, or
      * Use the :class:`Pool` and check-out the single, dedicated writer connection
        whenever you need a transaction.

      Example:

      .. code-block:: python

         async with db.atomic() as txn:
             await db.execute('insert into users (name) values (?)', ('alice',))

             async with db.atomic() as nested:
                 await db.execute('insert into users (name) values (?)', ('bob',))
                 await nested.rollback()  # Only 'bob' is rolled back.

                 await db.execute('insert into users (name) values (?)', ('carl',))

         # 'alice' and 'carl' are committed.

      Exceptions in nested blocks roll back the savepoint without affecting
      the outer transaction:

      .. code-block:: python

         async with db.atomic():
             await db.execute('insert into users (name) values (?)', ('alice',))

             try:
                 async with db.atomic():
                     await db.execute('insert into users (name) values (?)', ('alice',))
                     # IntegrityError - duplicate. Savepoint is rolled back.
             except IntegrityError:
                 pass

             # Outer transaction is unaffected. 'alice' is still pending.

         # 'alice' is committed.

   .. method:: transaction(lock=None)

      Create an async context-manager that runs queries in a transaction.

      :param str lock: lock type: ``DEFERRED``, ``IMMEDIATE``, or ``EXCLUSIVE``.
      :return: :class:`AsyncTransaction`

      Example:

      .. code-block:: python

         async with db.transaction() as txn:
             await db.execute('insert into users (name) values (?)', ('alice',))
             await db.execute('insert into users (name) values (?)', ('bob',))

         # Both rows committed.

      .. note::

         Most applications should prefer :meth:`AsyncConnection.atomic`, which
         automatically uses a transaction at the outermost level and
         savepoints for nested calls.

   .. method:: savepoint(sid=None)

      Create an async context-manager that runs queries in a savepoint.

      Calls to :meth:`~AsyncConnection.savepoint` can be nested.

      :param str sid: savepoint identifier (optional, auto-generated if omitted).
      :return: :class:`AsyncSavepoint`

   .. method:: changes()
      :async:

      Return the number of rows modified, inserted or deleted by the most
      recently completed INSERT, UPDATE or DELETE statement on the database
      connection.

      See `sqlite3_changes <https://www.sqlite.org/c3ref/changes.html>`_
      for details on what operations are counted.

      :rtype: int

   .. method:: last_insert_rowid()
      :async:

      :return: rowid of the most-recently inserted row.
      :rtype: int

   .. method:: pragma(*args, **kwargs)

      Execute a PRAGMA statement. Returns an awaitable.

      :param args: forwarded to :meth:`Connection.pragma`.
      :param kwargs: forwarded to :meth:`Connection.pragma`.

      Example:

      .. code-block:: python

         journal_mode = await db.pragma('journal_mode')
         await db.pragma('cache_size', -8000)

   .. method:: backup(dest, **kwargs)
      :async:

      Perform an online backup to the given destination :class:`AsyncConnection`.

      :param AsyncConnection dest: database to serve as destination for the backup.
      :param kwargs: forwarded to :meth:`Connection.backup`.

      Example:

      .. code-block:: python

         source = connect('app.db')
         dest = connect(':memory:')

         await source.backup(dest)

         count = await dest.execute_scalar('select count(*) from users')
         print(f'Backed up {count} users to in-memory copy.')

         await dest.close()
         await source.close()

   .. method:: backup_to_file(filename, **kwargs)
      :async:

      Perform an online backup to the given destination file.

      :param str filename: database file to serve as destination for the backup.
      :param kwargs: forwarded to :meth:`Connection.backup_to_file`.

   .. method:: checkpoint(**kwargs)
      :async:

      Perform a WAL checkpoint.

      :param kwargs: forwarded to :meth:`Connection.checkpoint`.
      :return: tuple of ``(wal_size, checkpointed_pages)``.
      :rtype: tuple

   .. method:: __aenter__()
               __aexit__(exc_type, exc_val, exc_tb)
      :async:

      Use the connection as an async context-manager. On exit, the connection
      is closed.

      .. code-block:: python

         async with connect('app.db') as db:
             await db.execute('select 1')

         # db is closed.


AsyncCursor
-----------

.. class:: AsyncCursor(conn, cursor)

   Async wrapper around a synchronous :class:`Cursor`. Returned by
   :meth:`AsyncConnection.execute`.

   .. method:: fetchone()
      :async:

      Fetch the next row from the result set.

      If no results are available or cursor has been consumed returns ``None``.

      :return: next row, or ``None`` if exhausted.

   .. method:: fetchall()
      :async:

      Fetch all remaining rows from the result set.

      :return: list of rows.
      :rtype: list

   .. method:: fetchmany(size=100, constructor=None)
      :async:

      Fetch up to *size* rows from the result set. Returns fewer than *size*
      rows if the result set is exhausted.

      :param int size: maximum number of rows to return.
      :param constructor: optional callable applied to the list of rows to
         build the result container.
      :return: list of rows, or container of rows if *constructor* given.

   .. method:: scalar()
      :async:

      Fetch the first column of the first row, or ``None`` if the result set
      is empty. Closes the cursor after reading.

      :return: scalar value or ``None``.

   .. method:: close()
      :async:

      Close the cursor, releasing the underlying synchronous :class:`Cursor`.
      Idempotent.

   .. property:: description

      Column description tuples for the current result set, or ``None`` if the
      last operation was a write that returned no columns. Each tuple contains
      ``(name,)``.

      This property reads from the synchronous cursor without dispatching.

   .. property:: lastrowid

      The rowid of the most-recently inserted row for this cursor, or ``None``.

      This property reads from the synchronous cursor without dispatching.

   .. property:: rowcount

      Return the count of rows modified by the last operation. Returns ``-1``
      for queries that do not modify data.

      This property reads from the synchronous cursor without dispatching.

   .. method:: __aiter__()
               __anext__()
      :async:

      Async iteration over the result set. Rows are fetched in batches of 100
      internally to amortize the cost of dispatching to the background thread.

      Example:

      .. code-block:: python

         curs = await db.execute('select * from events order by ts')
         async for row in curs:
             process(row)


Transaction Wrappers
--------------------

.. class:: AsyncAtomic(conn, lock=None)

   Async context-manager for :meth:`AsyncConnection.atomic`. Uses a transaction
   at the outermost level and savepoints for nested calls.

   .. method:: __aenter__()
      :async:

      Begin the transaction or savepoint.

   .. method:: __aexit__(exc_type, exc_val, exc_tb)
      :async:

      Commit the transaction or savepoint if exiting cleanly. If an unhandled
      exception occurred, roll back.

   .. method:: commit(*args)
      :async:

      Explicitly commit the underlying transaction.

   .. method:: rollback(*args)
      :async:

      Explicitly roll back the underlying transaction.


.. class:: AsyncTransaction(conn, lock=None)

   Async context-manager for :meth:`AsyncConnection.transaction`. Same API as
   :class:`AsyncAtomic`.


.. class:: AsyncSavepoint(conn, sid=None)

   Async context-manager for :meth:`AsyncConnection.savepoint`. Same API as
   :class:`AsyncAtomic`.


Pool
----

.. class:: Pool(database, readers=4, writer=True, **connect_kwargs)

   Async implementation of :class:`cysqlite.utils.Pool`.

   :param database: database filename.
   :type database: str, ``pathlib.Path``
   :param int readers: number of read-only connections to create.
   :param bool writer: create a dedicated writer connection.
   :param connect_kwargs: arguments for :func:`connect`

   Connection pool implementation that provides read-only connections and,
   optionally, a dedicated writer connection. Ensures that multiple writers are
   serialized, and that readers cannot lock the database. Requires WAL-mode.

   The following default pragmas are applied to all connections opened by the
   pool:

   * ``journal_mode = wal``
   * ``cache_size = -64000`` (64,000 KiB page cache)
   * ``mmap_size = 256 * 1024 * 1024`` (256MiB)
   * ``foreign_keys = 1`` (enable foreign-key constraint enforcement)

   .. method:: reader()

      :return: context-manager yielding a read-only :class:`AsyncConnection`.
      :raises: :class:`InterfaceError` if pool has been closed.

      Context-manager which checks out a read-only async connection from the pool.

      Example:

      .. code-block:: python

         pool = Pool('app.db')

         async with pool.reader() as conn:
             curs = await conn.execute('select ...')

   .. method:: writer()

      :return: context-manager yielding the read/write :class:`AsyncConnection`.
      :raises: :class:`InterfaceError` if pool has been closed or if writer
         connection was disabled.

      Context-manager which checks out the async writer connection from the
      pool. At the end of the wrapped block, if a transaction is active and
      un-committed the transaction is rolled-back.

      Example:

      .. code-block:: python

         pool = Pool('app.db')

         async with pool.writer() as conn:
             async with conn.atomic() as txn:
                 await conn.execute('insert ...')

   .. method:: close()
      :async:

      Close all connections.
