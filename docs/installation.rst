.. _installation:

Installation
============

cysqlite can be installed four ways:

* Binary wheel with SQLite embedded: ``pip install cysqlite``.
* Source build against the system SQLite:
  ``pip install --no-binary :all: cysqlite``.
* Self-contained build embedding SQLite, see :ref:`custom-builds`.
* Encrypted builds, see :ref:`sqlcipher-build` or :ref:`sqlite3mc-build`.

Wheels
------

.. code-block:: shell

    pip install cysqlite

Wheels embed the SQLite release current at the time of the cysqlite release,
compiled with most features enabled. Check any build with :func:`compile_option`:

.. code-block:: python

    >>> import cysqlite
    >>> cysqlite.sqlite_version
    '3.53.3'
    >>> cysqlite.compile_option('ENABLE_FTS5')
    1

Building from source
--------------------

Source builds need a C compiler and the Python development headers. Building
against the system SQLite additionally needs the SQLite development headers
(``libsqlite3-dev`` on Debian):

.. code-block:: shell

    # Build against the system sqlite.
    pip install --no-binary :all: cysqlite

To install the very latest commit:

.. code-block:: shell

    # (note: links against system sqlite)
    pip install -e git+https://github.com/coleifer/cysqlite.git#egg=cysqlite

.. _custom-builds:

Custom Builds
-------------

When ``sqlite3.c`` and ``sqlite3.h`` are present in the root of the cysqlite
checkout, they are compiled into the extension and the result is a fully
self-contained module. Use ``fetch_sqlite`` to download an amalgamation:

.. code-block:: shell

    git clone https://github.com/coleifer/cysqlite
    cd cysqlite/

    ./scripts/fetch_sqlite         # Current release, or:
    ./scripts/fetch_sqlite 3.51.2  # A specific version.

    pip install .

Verify the result:

.. code-block:: python

    >>> import cysqlite
    >>> cysqlite.sqlite_version
    '3.51.2'

Self-contained sdist
--------------------

You can also build a self-contained sdist from a checkout containing the sqlite
source amalgamation:

.. code-block:: shell

    ./scripts/fetch_sqlite 3.51.2
    python -m build --sdist  # dist/cysqlite-*.tar.gz embeds sqlite 3.51.2.

.. _sqlcipher-build:

SQLCipher
---------

`SQLCipher <https://github.com/sqlcipher/sqlcipher>`_ provides encryption.
It does not publish a source amalgamation, so cysqlite includes a script
that builds one. The script requires git, make, a C compiler and the OpenSSL
development headers (``libssl-dev`` on Debian):

.. code-block:: shell

    git clone https://github.com/coleifer/cysqlite
    cd cysqlite/

    ./scripts/fetch_sqlcipher         # Latest, or:
    ./scripts/fetch_sqlcipher v4.7.0  # A specific tag.

    pip install .

SQLCipher sources are detected automatically. Verify:

.. code-block:: python

    >>> db = cysqlite.connect('app.db')
    >>> db.execute_one('PRAGMA cipher_version')
    ('4.17.0 community',)

.. _sqlite3mc-build:

SQLite Multiple Ciphers
-----------------------

`SQLite3 Multiple Ciphers <https://utelle.github.io/SQLite3MultipleCiphers/>`_
also provides encryption, with no external crypto dependency. The
``fetch_sqlite3mc`` script downloads a release amalgamation:

.. code-block:: shell

    git clone https://github.com/coleifer/cysqlite
    cd cysqlite/

    ./scripts/fetch_sqlite3mc         # Latest release, or:
    ./scripts/fetch_sqlite3mc v2.5.0  # A specific tag.

    pip install .

Or do the same by hand with a zip from the
`releases page <https://github.com/utelle/SQLite3MultipleCiphers/releases>`_:

.. code-block:: shell

    unzip sqlite3mc-*-amalgamation.zip 'sqlite3mc_amalgamation.*'
    mv sqlite3mc_amalgamation.c sqlite3.c
    mv sqlite3mc_amalgamation.h sqlite3.h

Verify:

.. code-block:: python

    >>> db = cysqlite.connect('app.db')
    >>> db.execute("PRAGMA key='passphrase'")
    >>> db.execute_one('PRAGMA cipher')
    ('chacha20',)
