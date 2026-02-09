.. cysqlite documentation master file, created by
   sphinx-quickstart on Fri Feb  6 13:31:16 2026.
   You can adapt this file completely to your liking, but it should at least
   contain the root `toctree` directive.

cysqlite documentation
======================

.. image:: logo.png

cysqlite provides performant bindings to SQLite. cysqlite aims to be roughly
compatible with the behavior of the standard lib ``sqlite3`` module, but are
closer in spirit to ``apsw``, just with fewer features.

cysqlite supports standalone builds or dynamic-linking with the system SQLite.

``cysqlite`` is a Cython-based SQLite driver that provides:

* DB-API 2.0 compatible (mostly)
* Performant query execution
* Transaction management with context-managers and decorators
* User-defined functions, aggregates, window functions, and virtual tables
* BLOB support
* Row objects with dict-like access
* Schema introspection utilities

.. note::
   If you are looking for a SQLite driver that "just works" wherever your
   application will be used or installed (e.g. you are a library developer),
   the standard lib ``sqlite3`` is the best choice.

   If you are looking for a SQLite driver which exposes the full surface-area
   of SQLite APIs, ``apsw`` is the best choice.

.. note::
   cysqlite is well-supported by `peewee ORM <https://docs.peewee-orm.com/>`_.

Example usage:

.. code-block:: python

    from cysqlite import connect

    db = connect(':memory:')

    db.execute('create table data (k, v)')

    with db.atomic():
        db.executemany('insert into data (k, v) values (?, ?)',
                       [(f'k{i:02d}', f'v{i:02d}') for i in range(10)])
        print(db.last_insert_rowid())  # 10.

    curs = db.execute('select * from data')
    for row in curs:
        print(row)  # e.g., ('k00', 'v00')

    # We can use named parameters with a dict as well.
    row = db.execute_one('select * from data where k = :key and v = :val',
                         {'key': 'k50', 'val': 'v50'})
    print(row)  # ('k50', 'v50')

    db.close()

.. toctree::
   :maxdepth: 2
   :caption: Contents:

   installation
   sqlite-notes
   api
