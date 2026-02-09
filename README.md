## cysqlite

![](https://raw.githubusercontent.com/coleifer/cysqlite/refs/heads/master/docs/logo.png)

cysqlite provides performant bindings to SQLite. cysqlite aims to be roughly
compatible with the behavior of the standard lib `sqlite3` module, but are
closer in spirit to `apsw`, just with fewer features.

cysqlite supports standalone builds or dynamic-linking with the system SQLite.

[Documentation](https://cysqlite.readthedocs.io/en/latest/)

### Overview

`cysqlite` is a Cython-based SQLite driver that provides:

* DB-API 2.0 compatible (mostly)
* Performant query execution
* Transaction management with context-managers and decorators
* User-defined functions, aggregates, window functions, and virtual tables
* BLOB support
* Row objects with dict-like access
* Schema introspection utilities

### Installing

cysqlite can be installed as a pre-built binary wheel with SQLite embedded into
the module:

```shell
pip install cysqlite
```

cysqlite can be installed from a source distribution (sdist) which will link
against the system SQLite:

```shell
# Link against the system sqlite.
pip install --no-binary :all: cysqlite
```

If you wish to build cysqlite with encryption support, you can create a
self-contained build that embeds [SQLCipher](https://github.com/sqlcipher/sqlcipher).
At the time of writing SQLCipher does not provide a source amalgamation, so
cysqlite includes a script to build an amalgamation and place the sources into
the root of your checkout:

```shell
# Obtain checkout of cysqlite.
git clone https://github.com/coleifer/cysqlite

# Automatically download latest source amalgamation.
cd cysqlite/
./scripts/fetch_sqlcipher  # Will add sqlite3.c and sqlite3.h in checkout.

# Build self-contained cysqlite with SQLCipher embedded.
pip install .
```

### Example

Example usage:

```python
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
```
