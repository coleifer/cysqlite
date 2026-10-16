.. _user-defined-functions:

User-defined functions and hooks
================================

cysqlite lets you extend SQLite using ordinary Python callables: scalar
functions, aggregates, window functions, table-valued functions and collations.
It also exposes a set of connection hooks. Everything below
is registered on a :class:`Connection`, and functions and collations are
automatically re-registered if the connection is closed and re-opened.

See the :class:`Connection` methods in the :doc:`api` reference for details.

Scalar functions
----------------

A scalar function maps its arguments to a single value.

Use :meth:`Connection.create_function`:

.. code-block:: python

   def title_case(s):
       return s.title() if s else ''

   db.create_function(title_case)
   db.execute('select title_case(?)', ('heLLo wOrLd',)).fetchone()
   # ('Hello World',)

Aggregate functions
-------------------

An aggregate is a class with a ``step()`` method (called once per row) and a
``finalize()`` method (returns the result).

Use :meth:`Connection.create_aggregate`:

.. code-block:: python

   class Product:
       '''Like SUM(), but multiplies.'''
       def __init__(self):
           self.product = 1

       def step(self, value):
           self.product *= value

       def finalize(self):
           return self.product

   db.create_aggregate(Product)
   db.execute('select product(value) from data').fetchone()
   # (24,)

Window functions
----------------

A window function is an aggregate that additionally implements ``inverse()``
(remove a row from the window) and ``value()`` (the current running value).

Use :meth:`Connection.create_window_function`:

.. code-block:: python

   class MySum:
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

   db.create_window_function(MySum, 'mysum', 1)
   db.execute('select value, mysum(value) over '
              '(order by value rows 1 preceding) from data').fetchall()
   # [(1, 1), (2, 3), (3, 5), (4, 7)]

Table-valued functions
----------------------

Expose a generator (or any function returning an iterable of rows) as a table.
Each signature parameter becomes a function argument and parameters with a default
are optional.

Use :meth:`Connection.table_function`:

.. code-block:: python

   @db.table_function(columns=['value'])
   def series(start, stop, step=1):
       i = start
       while i < stop:
           yield (i,)
           i += step

   db.execute('select value from series(0, 10, 2)')  # 0, 2, 4, 6, 8

You can also use :meth:`Connection.create_table_function`. For writable tables,
``with_rowid``, or full control over the per-query lifecycle, subclass
:class:`TableFunction` directly.

Collations
----------

A collation is a function of two strings returning a negative number, zero, or
a positive number, used by ``ORDER BY ... COLLATE`` and similar.

Use :meth:`Connection.create_collation`:

.. code-block:: python

   def collate_reverse(s1, s2):
       return (s1 < s2) - (s1 > s2)

   db.create_collation(collate_reverse, 'reverse')
   db.execute('select name from users order by name collate reverse').fetchall()
   # [('carol',), ('bob',), ('alice',)]

Connection hooks
----------------

Commit and rollback hooks fire at transaction boundaries. Returning a
truthy value from the commit hook (or raising) turns the ``COMMIT`` into a
``ROLLBACK``:

.. code-block:: python

   readonly = True

   db.commit_hook(lambda: readonly)  # truthy return aborts the commit
   db.rollback_hook(lambda: log.info('rolled back'))

   db.commit_hook(None)              # clear the hook

The update hook fires for each row inserted, updated or deleted in a rowid
table:

.. code-block:: python

   def on_update(query_type, dbname, table, rowid):
       log.info('%s %s.%s rowid=%s', query_type, dbname, table, rowid)

   db.update_hook(on_update)

An authorizer is consulted as statements are compiled and can allow, deny, or
silently ignore individual operations:

.. code-block:: python

   def authorizer(op, p1, p2, p3, p4):
       if op == SQLITE_UPDATE and p1 == 'log':
           # Do not allow updates to the `log` table.
           return SQLITE_DENY
       return SQLITE_OK

   db.authorizer(authorizer)

See :meth:`Connection.commit_hook`, :meth:`Connection.rollback_hook`,
:meth:`Connection.update_hook` and :meth:`Connection.authorizer`. For SQL
tracing, see :meth:`Connection.trace`.
