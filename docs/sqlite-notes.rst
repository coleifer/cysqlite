.. _sqlite-notes:

SQLite Notes
============

SQLite's type system is different from other databases. SQLite stores data in
five simple types:

+-------------------------------+-------------+
| Python type                   | SQLite type |
+===============================+=============+
| ``None``                      | ``NULL``    |
+-------------------------------+-------------+
| ``int``, ``bool``             | ``INTEGER`` |
+-------------------------------+-------------+
| ``float``, ``Decimal``        | ``REAL``    |
+-------------------------------+-------------+
| ``str``                       | ``TEXT``    |
+-------------------------------+-------------+
| ``bytes`` / buffers           | ``BLOB``    |
+-------------------------------+-------------+

Notably SQLite does not natively support:

* datetime / date - store these as ISO-formatted text or as unix timestamps.
* fixed-precision decimals - no native type. cysqlite stores ``Decimal`` as
  ``REAL`` by default, which can lose precision for values that aren't exactly
  representable as floats. Register a custom :ref:`adapter <sqlite-notes-adapters>`
  to store as ``TEXT`` if exact precision is required. Alternately store
  currency as a scaled integer.
* boolean - emulated as integer ``1`` and ``0``.
* json - SQLite has JSON support, but it is stored as ``TEXT`` or ``BLOB``
  (for JSONB).

SQLite will store any value in a column regardless of its declared type, using
`type affinity <https://www.sqlite.org/datatype3.html#type_affinity>`_ to
influence how the data is stored. Strict typing is opt-in with `strict tables <https://www.sqlite.org/stricttables.html>`_
(requires SQLite 3.37.0+).

For convenience, cysqlite applies the following rules for adapting Python types
to match SQLite's available data-types:

+-------------------------------+-------------------------------------------+
| Python type                   | SQLite type                               |
+===============================+===========================================+
| ``datetime``                  | ``TEXT`` (isoformat with ' ' delimiter)   |
+-------------------------------+-------------------------------------------+
| ``date``, ``time``            | ``TEXT`` (isoformat)                      |
+-------------------------------+-------------------------------------------+
| ``Fraction``, ``Decimal``,    | ``REAL``                                  |
| ``__float__()``               |                                           |
+-------------------------------+-------------------------------------------+
| ``UUID``                      | ``TEXT``                                  |
+-------------------------------+-------------------------------------------+
| **Anything else**             | Use :meth:`Connection.register_adapter`.  |
+-------------------------------+-------------------------------------------+

Examples:

.. code-block:: python

   values = [
       None,
       1,
       2.3,
       'a text \u2012 string',
       b'\x00\xff\x00\xff',
       bytearray(b'this is a buffer'),
       datetime(2026, 1, 2, 3, 4, 5).astimezone(timezone.utc),
       datetime(2026, 2, 3, 4, 5, 6),
       date(2026, 3, 4),
       uuid.uuid4(),  # str()
   ]

   for value in values:
       row = db.execute_one('select typeof(?), ?', (value, value))
       print(row)

   # ('null',    None)
   # ('integer', 1)
   # ('real',    2.3)
   # ('text',    'a text ‒ string')
   # ('blob',    b'\x00\xff\x00\xff')
   # ('blob',    b'this is a buffer')
   # ('text',    '2026-01-02 03:04:05+00:00')
   # ('text',    '2026-02-03 04:05:06')
   # ('text',    '2026-03-04')
   # ('text',    '0c4ca10a-56ab-470a-9357-d28366d97ceb')

.. _sqlite-notes-adapters:

Adapters
---------

You can add custom adapters to control exactly how Python types are sent to
SQLite using :meth:`Connection.register_adapter` and the :meth:`~Connection.adapter`
decorator. For example, it may be desirable to store ``Decimal`` values as
``TEXT`` in order to avoid floating-point precision issues, or to store ``date``
as an 8-digit integer:

.. code-block:: python

   db.register_adapter(Decimal, str)

   @db.adapter(date)
   def adapt_date(value):
       return int(value.strftime('%Y%m%d'))

   values = [
       date(2026, 3, 4),
       Decimal('1.3'),
   ]

   for value in values:
       row = db.execute_one('select typeof(?), ?', (value, value))
       print(row)

   # ('integer', 20260304)
   # ('text',    '1.3')

.. _sqlite-converters:

Converters
-----------

By default, no special attempts at type inference are applied to data coming
**from** SQLite.

To convert data going from SQLite into Python, you will need to register one or
more converters using :meth:`Connection.register_converter` or using the
:meth:`Connection.converter` decorator. Converters rely on the SQLite
`sqlite3_column_decltype <https://www.sqlite.org/c3ref/column_decltype.html>`_
API, which retrieves the declared type of the given column. cysqlite then
applies your converter for any type that was registered.

For example, to convert columns declared ``DATETIME`` back to Python datetimes:

.. code-block:: python

   db = cysqlite.connect(':memory:')

   db.register_converter('datetime', datetime.datetime.fromisoformat)

   # Or use a decorator:
   @db.converter('datetime')
   def convert_datetime(value):
       # Converts our ISO-formatted date string into a python datetime.
       return datetime.datetime.fromisoformat(value)

If the value is ``NULL`` then the convert function is **not** applied, so you
do not need to test for ``value is None``.

Below are some examples:

.. code-block:: python

   db = cysqlite.connect(':memory:')

   @db.converter('datetime')
   def convert_datetime(value):
       # Converts our ISO-formatted date string into a python datetime.
       return datetime.datetime.fromisoformat(value)

   # Automatically parse and load data declared as JSON.
   db.register_converter('json', json.loads)

   # Handle decimal data.
   @db.converter('numeric')
   def convert_numeric(value):
       return Decimal(value).quantize(Decimal('1.00'))

   db.execute('create table vals (ts datetime, js json, dec numeric(10, 2))')

   # Create a TZ-aware datetime and a JSON object.
   ts = datetime.datetime(2026, 1, 2, 3, 4, 5).astimezone(datetime.timezone.utc)
   js = {'key': {'nested': 'value'}, 'arr': ['i0', 1, 2., None]}
   dec = Decimal('1.3')

   # When we INSERT the JSON, we need to dump it to string.
   db.execute('insert into vals (ts, js, dec) values (?, ?, ?)',
              (ts, json.dumps(js), dec))

   # When reading back the data, it is converted automatically based on
   # the declared column types.
   row = db.execute_one('select * from vals')
   assert row == (ts, js, dec)

The converter accepts a ``data_type`` and uses the following rules for matching
a specified data-type to what SQLite tells us:

* Matching is case-insensitive, e.g. ``JSON`` or ``json`` is fine.
* Split on the first space or ``"("`` character, e.g. if SQLite
  tells us the data-type is ``NUMERIC(10, 2)``, cysqlite will attempt to
  find a converter named ``numeric``.

Differences from stdlib
-----------------------

The stdlib ``sqlite3`` module uses different conventions for registering
adapters and converters:

* Adapters and converters in ``sqlite3`` are registered globally. In
  ``cysqlite``, they are scoped to the :class:`Connection`.
* ``sqlite3`` converters - functions that transform values coming from
  SQLite back into richer Python types - are disabled by default, and are
  enabled via the ``detect_types`` parameter on ``connect()``. Two modes
  are available: matching against the column's declared type
  (``PARSE_DECLTYPES``) and matching against a type hint embedded in a
  column alias (``PARSE_COLNAMES``). cysqlite always matches against
  declared types, and has no column-alias mechanism.
* ``sqlite3`` has a separate adaptation mechanism that checks for a
  ``__conform__()`` method on the object being bound. The method's return
  value is used in place of the original. cysqlite has no equivalent -
  bind either a supported type directly, or register an adapter.
* ``sqlite3`` historically shipped default adapters for ``datetime`` and
  ``date``, and also handled ``datetime`` via two magic type names, but
  these are deprecated as of Python 3.12.

cysqlite is more permissive about what types it will accept at bind time.
``UUID`` objects are bound as ``TEXT``. Any object with a ``__float__`` method
(e.g. ``Decimal``, ``Fraction``) is bound as ``REAL``. Unsupported types raise
``TypeError`` and require an adapter to handle them directly. Additionally,
cysqlite provides ISO-8601 formatting for ``datetime``, ``date`` and ``time``
out of the box with no surprise deprecations. SQLite's built-in `date functions <https://sqlite.org/lang_datefunc.html>`_
work well on ISO-8601 format, so this allows date/times stored by ``cysqlite``
to be usable with the builtin date functions.

.. _transactions:

Transactions
============

cysqlite operates in pure autocommit mode as this is how SQLite itself operates.
Statements execute immediately unless you've explicitly opened a transaction.
The driver never issues implicit transaction control statements. To use
transactions, open one with :meth:`~Connection.atomic`, :meth:`~Connection.transaction`,
:meth:`~Connection.begin`, or by executing ``BEGIN`` directly.

.. code-block:: python

   db = connect(':memory:')

   # Autocommit: each statement is its own transaction.
   db.execute('create table t (x)')
   db.execute('insert into t values (1)')  # Committed immediately.

   # Explicit transaction via context manager, supports nesting.
   with db.atomic():
       db.execute('insert into t values (2)')
       db.execute('insert into t values (3)')
   # Committed on successful exit, rolled back on exception.

   # Or manage it explicitly.
   db.begin()
   try:
       db.execute('insert into t values (4)')
       db.commit()
   except:
       db.rollback()
       raise

:attr:`~Connection.in_transaction` uses ``sqlite3_get_autocommit()`` to detect
if a transaction is currently active.

Why autocommit
--------------

SQLite allows only one writer at a time, and a transaction that has performed
**any** write will hold the write lock until it commits or rolls back. An
application that holds transactions open longer than necessary, even by
accident, will see ``OperationalError: database is locked`` under concurrency.
The standard lib ``sqlite3`` makes this class of bug trivially easy to write.
You execute an ``UPDATE``, a transaction opens silently, and then your
application spends more time issuing ``SELECT`` queries or handling other
things before you call ``commit()``, which finally releases the lock.

``sqlite3`` transactions use a `string prefix compare <https://github.com/python/cpython/blob/80ba4e10f5070e6d2e35618e08057be44f913965/Modules/_sqlite/statement.c#L82-L91>`_
to detect if a statement is data-modifying, which triggers the silent ``BEGIN``.
Even in Python 3.14, if the statement starts with ``INSERT``, ``UPDATE``, ``DELETE``,
or ``REPLACE``, the driver automatically begins a transaction before executing
it. This misses things like queries using CTEs, among other interesting
failure modes.

Before Python 3.12, sqlite3 used the ``isolation_level`` parameter to control
driver-managed transactions. By default a transaction auto-begins before any
DML statement using the string compare. This transaction is held open until you
call ``commit()`` or ``rollback()``. The ``isolation_level`` parameter controls
what lock ``BEGIN`` acquires, but by passing ``isolation_level=None`` you can
disable driver transaction management and get something reasonable.

.. code-block:: python

   # Specifying isolation_level=None tells sqlite3 to leave transaction
   # management alone.
   >>> db = sqlite3.connect(':memory:', isolation_level=None)

   # Wait, what's this? Legacy??
   >>> db.autocommit == sqlite3.LEGACY_TRANSACTION_CONTROL
   True

   # Whatever, at least we are in autocommit mode.
   >>> db.in_transaction
   False

   # Run a transaction.
   >>> db.execute('begin')
   >>> db.in_transaction
   True

   # Let's get out of this transaction.
   >>> db.commit()
   >>> db.in_transaction
   False

At time of writing this still works, but the ``LEGACY_`` prefix indicates it
may be deprecated soon. In place of isolation level, CPython has a new,
completely separate alternative:

.. code-block:: python

   # Let's do it the way modern Python wants us to.
   >>> db = sqlite3.connect(':memory:', autocommit=True)

   # Isolation level returns an empty string. Empty. It means whatever you
   # want it to mean.
   >>> db.isolation_level
   ''

   >>> db.in_transaction
   False

   # So far so good.
   >>> db.execute('begin')
   >>> db.in_transaction
   True

   # Wait, what the fuck?!
   >>> db.commit()
   >>> db.in_transaction
   True

   >>> db.execute('commit -- who thought this was a good idea?!')
   >>> db.in_transaction
   False

If you didn't catch what happened there, when we set ``autocommit=True``, Python
**silently** turned ``commit()`` into a no-op. No deprecation warning, no
exception. If you call ``commit()`` and then close the connection, or let it be
garbage-collected, all your changes are silently lost.

The other direction is just as bad. With ``autocommit=False`` (which the
docs now recommend), a transaction begins immediately on connection, lasts
until you commit, and a fresh one begins right after. Every connection is
always in a transaction. This is problematic because of the way SQLite upgrades
the lock when a write occurs, retaining it until a commit/rollback occurs.

cysqlite's answer to all of this:

* :meth:`~Connection.begin` begins.
* :meth:`~Connection.commit` commits.
* :meth:`~Connection.rollback` rolls back.
* :meth:`~Connection.atomic` provides a context-manager or decorator that wraps
  the block in a transaction or savepoint. Calls can be nested.

.. _transactions-recommended:

Recommended patterns
--------------------

:meth:`~Connection.atomic` can wrap a block of code or decorate a function with
transaction semantics, and supports nesting. It opens a transaction at the
outermost level and a savepoint for nested calls:

.. code-block:: python

   with db.atomic():
       db.execute('insert into orders (user_id, total) values (?, ?)',
                  (user_id, total))
       for item in line_items:
           db.execute('insert into order_items (...) values (...)', item)
   # Commits on clean exit, rolls back if anything raised.

Atomic blocks nest **correctly**. A failure inside a nested block rolls back
the savepoint without affecting the outer transaction:

.. code-block:: python

   with db.atomic():
       db.execute('insert into users (name) values (?)', ('alice',))

       try:
           with db.atomic():
               db.execute('insert into users (name) values (?)', ('alice',))
               # IntegrityError - savepoint is rolled back.
       except IntegrityError:
           pass

       # Outer transaction is unaffected. 'alice' is still pending.

   # 'alice' is committed.

If you need a specific lock type, pass ``lock=``. Use ``IMMEDIATE`` when
you know you're going to write and want to fail fast if another writer holds
the lock:

.. code-block:: python

   with db.atomic(lock='IMMEDIATE'):
       db.execute('update counters set n = n + 1 where id = ?', (id_,))

If you explicitly want a flat transaction without savepoint nesting, use
:meth:`~Connection.transaction` instead of :meth:`~Connection.atomic`.
Nested ``transaction()`` calls do not commit on the inner levels. Only the
outermost block commits.

For partial rollbacks within a larger transaction, :meth:`~Connection.atomic`
(or :meth:`~Connection.savepoint`) provides savepoints that can be committed or
rolled-back within a larger atomic context:

.. code-block:: python

   with db.atomic():
       db.execute('insert into log (msg) values (?)', ('step 1',))

       with db.atomic() as sp:
           db.execute('insert into log (msg) values (?)', ('step 2',))
           if something_went_wrong:
               sp.rollback()  # Undo step 2 only.

       db.execute('insert into log (msg) values (?)', ('step 3',))

As a decorator, any of the three helpers wraps the decorated function
in a transaction/savepoint:

.. code-block:: python

   @db.atomic()
   def transfer_funds(from_id, to_id, amount):
       db.execute('update accounts set bal = bal - ? where id = ?',
                  (amount, from_id))
       db.execute('update accounts set bal = bal + ? where id = ?',
                  (amount, to_id))

For all other cases you can explicitly call :meth:`~Connection.begin`,
:meth:`~Connection.commit` and :meth:`~Connection.rollback` (or execute the SQL
directly via ``execute()``).
