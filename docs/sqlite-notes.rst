.. _sqlite-notes:

SQLite Notes
============

SQLite's type system is different from other databases. In the first place, it
is much more flexible in what types of data it will store in a column, even if
the column declares a particular data-type. SQLite stores data in five simple
types, and notably does not natively support DATETIME / DATE / JSON. Instead
these are all emulated using either TEXT or numeric types (e.g. timestamps).

The following shows the correspondence between Python types and SQLite types:

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

Additionally, for convenience, cysqlite applies the following rules for
adapting Python types:

+-------------------------------+------------------------------------------+
| Python type                   | SQLite type                              |
+===============================+==========================================+
| ``datetime``                  | ``TEXT`` (isoformat with ' ' delimiter). |
+-------------------------------+------------------------------------------+
| ``date``                      | ``TEXT`` (isoformat)                     |
+-------------------------------+------------------------------------------+
| ``Fraction``, ``Decimal``,    | ``REAL``                                 |
| ``__float__()``               |                                          |
+-------------------------------+------------------------------------------+
| **Anything else**             | ``TEXT`` (coerced to ``str()``)          |
+-------------------------------+------------------------------------------+

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

By default, no special attempts at type inference are applied to data coming
**from** SQLite. As you can see in the above example, all our Python values
were coerced to reasonable SQLite-friendly representations. But that richness
is lost when going from SQLite to Python without specific helpers that read the
column type of the value.

.. _sqlite-converters:

To convert data coming going SQLite to Python, you will need to register one or
more converters using :meth:`Connection.register_converter` or using the
:meth:`Connection.converter` decorator. Below are some examples:

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

   # When we INSERT the JSON, note that we need to dump it to string.
   db.execute('insert into vals (ts, js, dec) values (?, ?, ?)',
              (ts, json.dumps(js), dec))

   # When reading back the data, it is converted automatically based on
   # the declared column types.
   row = db.execute_one('select * from vals')
   assert row == (ts, js, dec)

The converter accepts a ``data_type`` and uses the following rules for matching
a specified data-type to what SQLite tells us:

* Matching is case-insensitive, e.g. ``JSON`` or ``json`` is fine.
* If a registered data-type is a complete match, use it.
* Otherwise split on the first whitespace or ``"("`` character and look for
  that, e.g. ``NUMERIC(10, 2)`` will match our registered ``numeric``
  converter.
