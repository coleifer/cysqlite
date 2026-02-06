.. _installation:

Installation
============

cysqlite can be installed as a pre-built binary wheel with SQLite embedded into
the module:

.. code-block:: console

   pip install cysqlite

cysqlite can be installed from a source distribution (sdist) which will link
against the system SQLite:

.. code-block:: console

    # Link against the system sqlite.
    pip install --no-binary :all: cysqlite

To install the very latest commit:

.. code-block:: console

    # (note: links against system sqlite)
    pip install -e git+https://github.com/coleifer/cysqlite.git#egg=cysqlite

Custom Builds
-------------

To build with a specific SQLite version, obtain or build a source amalgamation
of the `SQLite release <https://www.sqlite.org/chronology.html>`_ you intend to
use. Then extract or copy the `sqlite3.c` and `sqlite3.h` files into the root
of your `cysqlite` checkout and build:

.. code-block:: console

    # Obtain SQLite source amalgamation.
    wget -O sqlite.zip https://www.sqlite.org/2026/sqlite-amalgamation-3510200.zip

    # Extract sqlite3.c and sqlite3.h into the current directory.
    unzip -j sqlite.zip '*/sqlite3.[ch]'

    # Obtain checkout of cysqlite.
    git clone https://github.com/coleifer/cysqlite

    # Copy SQLite sources into checkout of cysqlite.
    cp sqlite3.[ch] cysqlite/

    # Build self-contained cysqlite with SQLite sources.
    cd cysqlite/
    pip install .

For convenience cysqlite includes a script to fetch the latest source
amalgamation and place the sources into the root of your checkout:

.. code-block:: console

    # Obtain checkout of cysqlite.
    git clone https://github.com/coleifer/cysqlite

    # Automatically download latest source amalgamation.
    cd cysqlite/
    ./scripts/fetch_sqlite  # Will add sqlite3.c and sqlite3.h in checkout.

    # Build self-contained cysqlite.
    pip install .

SQLCipher
---------

If you wish to build cysqlite with encryption support, you can create a
self-contained build that embeds `SQLCipher <https://github.com/sqlcipher/sqlcipher>`_.
At the time of writing SQLCipher does not provide a source amalgamation, so
cysqlite includes a script to build an amalgamation and place the sources into
the root of your checkout:

.. code-block:: console

    # Obtain checkout of cysqlite.
    git clone https://github.com/coleifer/cysqlite

    # Automatically download latest source amalgamation.
    cd cysqlite/
    ./scripts/fetch_sqlcipher  # Will add sqlite3.c and sqlite3.h in checkout.

    # Build self-contained cysqlite with SQLCipher embedded.
    pip install .

Building the SQLCipher amalgamation yourself:

.. code-block:: console

    # Obtain SQLCipher source code.
    git clone https://github.com/sqlcipher/sqlcipher
    cd sqlcipher/

    # Flags to ensure we have all the features we need.
    export CFLAGS="-DSQLITE_DEFAULT_CACHE_SIZE=-8000 \
        -DSQLITE_DEFAULT_FOREIGN_KEYS=1 \
        -DSQLITE_DEFAULT_MEMSTATUS=0 \
        -DSQLITE_DEFAULT_PAGE_SIZE=4096 \
        -DSQLITE_ENABLE_EXPLAIN_COMMENTS \
        -DSQLITE_ENABLE_FTS3_PARENTHESIS \
        -DSQLITE_ENABLE_FTS3 \
        -DSQLITE_ENABLE_FTS4 \
        -DSQLITE_ENABLE_FTS5 \
        -DSQLITE_ENABLE_JSON1 \
        -DSQLITE_ENABLE_MEMDB \
        -DSQLITE_ENABLE_STAT4 \
        -DSQLITE_ENABLE_UNLOCK_NOTIFY \
        -DSQLITE_ENABLE_UPDATE_DELETE_LIMIT \
        -DSQLITE_LIKE_DOESNT_MATCH_BLOBS \
        -DSQLITE_SOUNDEX \
        -DSQLITE_USE_URI \
        -DSQLITE_TEMP_STORE=3 \
        -DSQLITE_HAS_CODEC=1 \
        -DHAVE_STDINT_H=1 \
        -O2"

    ./configure --disable-tcl --fts3 --fts4 --fts5 --update-limit \
        --enable-load-extension --enable-threadsafe

    # Build the source amalgamation.
    make sqlite3.c sqlite3.h

    # Now copy the sqlite3.c and sqlite3.h into the root of your cysqlite
    # checkout.
    cp sqlite3.[ch] /path/to/cysqlite/

    # Build self-contained cysqlite with SQLCipher.
    cd /path/to/cysqlite/
    pip install .
