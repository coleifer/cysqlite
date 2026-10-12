.. _migration:

Migrating from ``sqlite3``
==========================

A side-by-side reference for switching from the stdlib ``sqlite3`` module
to cysqlite. For the design rationale, see :ref:`sqlite-notes`.

Connection
----------

.. list-table::
   :header-rows: 1
   :widths: 50 50

   * - stdlib ``sqlite3``
     - cysqlite
   * - .. code-block:: python

           db = sqlite3.connect('app.db')
     - .. code-block:: python

           db = cysqlite.connect('app.db')

   * - .. code-block:: python

           db = sqlite3.connect('app.db')
           db.execute('PRAGMA journal_mode=WAL')
     - .. code-block:: python

           db = cysqlite.connect(
               'app.db',
               journal_mode='wal')

Transactions
------------

The stdlib opens transactions implicitly by string-matching DML
statements. cysqlite operates in pure autocommit and uses an explicit
context manager. ``atomic()`` uses a real transaction at the outer
level and a savepoint when nested - no manual ``SAVEPOINT`` needed.

.. list-table::
   :header-rows: 1
   :widths: 50 50

   * - stdlib ``sqlite3``
     - cysqlite
   * - .. code-block:: python

           db.execute(
               'INSERT INTO t VALUES (?)', (1,))
           db.commit()
     - .. code-block:: python

           with db.atomic():
               db.execute(
                   'INSERT INTO t VALUES (?)', (1,))

   * - .. code-block:: python

           with db:
               db.execute(...)
     - .. code-block:: python

           with db.atomic():
               db.execute(...)

   * - .. code-block:: python

           db.execute('SAVEPOINT sp')
           try:
               ...
               db.execute('RELEASE SAVEPOINT sp')
           except Exception:
               db.execute('ROLLBACK TO SAVEPOINT sp')
               raise
     - .. code-block:: python

           with db.atomic():  # supports nesting.
               with db.atomic():
                   ...

Row factories
-------------

cysqlite's ``Row`` factory provides attribute access and ``.as_dict()`` on top
of the stdlib's index/name/keys interface. Name lookup is case-sensitive in
cysqlite, case-insensitive in stdlib.

.. list-table::
   :header-rows: 1
   :widths: 50 50

   * - stdlib ``sqlite3``
     - cysqlite
   * - .. code-block:: python

           db.row_factory = sqlite3.Row
           row = db.execute(...).fetchone()
           row[0]; row['name']; row.keys()
     - .. code-block:: python

           db.row_factory = cysqlite.Row
           row = db.execute(...).fetchone()
           row[0]; row['name']; row.name
           row.as_dict()

   * - .. code-block:: python

           def dict_factory(cur, row):
               cols = [d[0]
                       for d in cur.description]
               return dict(zip(cols, row))
           db.row_factory = dict_factory
     - .. code-block:: python

           db.row_factory = cysqlite.dict_factory

Adapters and converters
-----------------------

stdlib registers globally, while cysqlite registers per connection. There is
no ``detect_types`` flag. Converters always consult the declared column type.

.. list-table::
   :header-rows: 1
   :widths: 50 50

   * - stdlib ``sqlite3``
     - cysqlite
   * - .. code-block:: python

           sqlite3.register_adapter(dict, json.dumps)
           sqlite3.register_converter('JSON',
                                      json.loads)
           db = sqlite3.connect(
               'x.db',
               detect_types=sqlite3.PARSE_DECLTYPES)
     - .. code-block:: python

           db = cysqlite.connect('x.db')
           db.register_adapter(dict, json.dumps)
           db.register_converter('JSON', json.loads)

executescript
-------------

stdlib implicitly commits any open transaction first while cysqlite does
not. Wrap explicitly if you want script-as-atomic-unit.

.. list-table::
   :header-rows: 1
   :widths: 50 50

   * - stdlib ``sqlite3``
     - cysqlite
   * - .. code-block:: python

           db.executescript(schema_sql)
     - .. code-block:: python

           with db.atomic():
               db.executescript(schema_sql)

Error handling
--------------

cysqlite splits ``IntegrityError`` and ``OperationalError`` based on the
error code, so you can catch the specific error (e.g. duplicate
``PRIMARY KEY`` raises ``PrimaryKeyIntegrityError``):

.. list-table::
   :header-rows: 1
   :widths: 50 50

   * - stdlib ``sqlite3``
     - cysqlite
   * - .. code-block:: python

           try:
               db.execute(...)
           except sqlite3.IntegrityError as e:
               if e.sqlite_errorname == \
                  'SQLITE_CONSTRAINT_UNIQUE':
                   ...
     - .. code-block:: python

           from cysqlite import \
               UniqueIntegrityError
           try:
               db.execute(...)
           except UniqueIntegrityError:
               ...

Available subclasses:

* ``IntegrityError``: ``UniqueIntegrityError``,
  ``NotNullIntegrityError``, ``ForeignKeyIntegrityError``,
  ``CheckIntegrityError``, ``PrimaryKeyIntegrityError``
* ``OperationalError``: ``DiskFullError``, ``ReadOnlyError``,
  ``DatabaseLockedError``, ``AuthorizationError``

Exception messages include the failing SQL and both error codes::

    UniqueIntegrityError: error executing query:
    [INSERT INTO users(email) VALUES (?)]
    UNIQUE constraint failed: users.email (code=19, ext=2067)

User-defined functions
----------------------

cysqlite takes the callable first and the name as an optional keyword argument.

.. list-table::
   :header-rows: 1
   :widths: 50 50

   * - stdlib ``sqlite3``
     - cysqlite
   * - .. code-block:: python

           db.create_function(
               'doubler', 1, lambda x: x * 2,
               deterministic=True)
     - .. code-block:: python

           db.create_function(
               lambda x: x * 2,
               name='doubler', nargs=1,
               deterministic=True)

   * - .. code-block:: python

           db.create_aggregate('avg2', 1, Avg)
     - .. code-block:: python

           db.create_aggregate(
               Avg, name='avg2', nargs=1)

BLOBs
-----

.. list-table::
   :header-rows: 1
   :widths: 50 50

   * - stdlib ``sqlite3`` (3.11+)
     - cysqlite
   * - .. code-block:: python

           with db.blobopen(
                   't', 'data', rowid) as blob:
               blob.read(100)
     - .. code-block:: python

           with db.blob_open(
                   't', 'data', rowid) as blob:
               blob.read(100)
               blob.readline()       # full RawIOBase
               blob.reopen(other_rowid)

Behaviors that change in your tests
-----------------------------------

* ``commit()`` and ``rollback()`` raise :class:`OperationalError` when
  no transaction is open. Or wrap writes in ``with db.atomic():``.
* ``executescript`` runs inside any open transaction rather than
  implicitly committing. Consider wrapping with ``atomic()``.
* ``cysqlite.Row`` is case-sensitive on string lookup, stdlib's is
  case-insensitive.
* ``autocommit`` is a method here, not the settable attribute stdlib 3.12
  added. ``if db.autocommit:`` is always true because it references the
  bound method, so call ``db.autocommit()``.
  :attr:`~Connection.in_transaction` is a property in both.
* Anywhere you parsed an ``IntegrityError`` message, catch the exact
  subclass instead.
