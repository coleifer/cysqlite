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

At the time of writing, no special attempts at type inference are applied to
data coming **from** SQLite. As you can see in the above example, all our
Python values were coerced to reasonable SQLite-friendly representations. But
that richness is lost when going from SQLite to Python without specific helpers
like the *converters* in ``sqlite3``. A future release may add converters for
data going from SQLite to Python.
