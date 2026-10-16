.. _utils:

Utils
=====

.. module:: cysqlite.utils

.. function:: slow_query_log(conn, threshold_ms=50, logger=None, level=logging.WARNING, expand_sql=True)

   :param Connection conn: cysqlite connection to install slow query trace.
   :param int threshold_ms: threshold for logging slow queries.
   :param str logger: namespace to log slow queries to, default ``'cysqlite.utils'``.
   :param int level: loglevel for slow queries.
   :param bool expand_sql: expand bound parameters in query.

   Register a ``sqlite3_trace_v2`` callback that will log slow queries to
   the given logger. Overrides previously-registered :py:meth:`~Connection.trace`.


.. class:: Pool(database, readers=4, writer=True, **connect_kwargs)

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

   Example:

   .. code-block:: python

      # Override only the page cache size.
      pool = Pool('app.db', pragmas={'cache_size': -128000})

      with pool.writer() as conn:
          conn.execute('create table if not exists users ('
                       '"id" integer not null primary key, '
                       '"username" text not null)')

          conn.execute('insert into users (username) values (?)', ('alice',))

      with pool.reader() as conn:
          curs = conn.execute('select * from users')

          # Raises ReadOnlyError - connection is read-only.
          conn.execute('insert into users (username) values (?)', ('bob',))

   .. method:: reader()

      :return: context-manager yielding a read-only :class:`Connection`.
      :raises: :class:`InterfaceError` if pool has been closed.

      Context-manager which checks out a read-only connection from the pool.

   .. method:: writer()

      :return: context-manager yielding the read/write :class:`Connection`.
      :raises: :class:`InterfaceError` if pool has been closed or if writer
         connection was disabled.

      Context-manager which checks out the writer connection from the pool. At
      the end of the wrapped block, if a transaction is active and un-committed
      the transaction is rolled-back.

   .. method:: close()

      Close all connections. If the writer is checked out, waits for it to be
      returned, so calling ``close()`` inside a :meth:`writer` block deadlocks.
      Readers that are checked out are closed when they are returned.
