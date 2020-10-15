import hashlib

from cysqlite import Connection

from peewee import __exception_wrapper__
from peewee import logger
from peewee import *


class CySqliteDatabase(SqliteDatabase):
    def _connect(self):
        conn = Connection(self.database, timeout=self._timeout * 1000,
                          extensions=True, **self.connect_params)
        conn.connect()
        try:
            self._add_conn_hooks(conn)
        except:
            conn.close()
            raise
        return conn

    def _add_conn_hooks(self, conn):
        if self._attached:
            self._attach_databases(conn)
        if self._pragmas:
            self._set_pragmas(conn)
        self._load_aggregates(conn)
        self._load_collations(conn)
        self._load_functions(conn)
        if self.server_version >= (3, 25, 0):
            self._load_window_functions(conn)
        if self._table_functions:
            for table_function in self._table_functions:
                table_function.register(conn)
        if self._extensions:
            self._load_extensions(conn)

    def _set_pragmas(self, conn):
        for pragma, value in self._pragmas:
            conn.execute_one('PRAGMA %s = %s;' % (pragma, value))

    def _attach_databases(self, conn):
        for name, db in self._attached.items():
            conn.execute_one('ATTACH DATABASE "%s" AS "%s"' % (db, name))

    @property
    def timeout(self):
        return self._timeout

    @timeout.setter
    def timeout(self, seconds):
        if self._timeout == seconds:
            return

        self._timeout = seconds
        if not self.is_closed():
            # pysqlite multiplies the user timeout by 1000, but the unit of the
            # pragma is actually milliseconds.
            self.execute_sql('PRAGMA busy_timeout=%d;' % (seconds * 1000))

    def _load_aggregates(self, conn):
        for name, (klass, num_params) in self._aggregates.items():
            conn.create_aggregate(klass, name, num_params)

    def _load_collations(self, conn):
        for name, fn in self._collations.items():
            conn.create_collation(fn, name)

    def _load_functions(self, conn):
        for name, (fn, num_params) in self._functions.items():
            conn.create_function(fn, name, num_params)

    def _load_window_functions(self, conn):
        for name, (klass, num_params) in self._window_functions.items():
            conn.create_window_function(klass, name, num_params)

    def _load_extensions(self, conn):
        conn.enable_load_extensions(True)
        for extension in self._extensions:
            conn.load_extension(extension)

    def load_extension(self, extension):
        self._extensions.add(extension)
        if not self.is_closed():
            conn = self.connection()
            conn.load_extension(extension)

    def unload_extension(self, extension):
        self._extensions.remove(extension)

    def last_insert_id(self, cursor, query_type=None):
        return self.connection().last_insert_rowid()

    def rows_affected(self, cursor):
        return self.connection().changes()

    def begin(self, lock_type='deferred'):
        self.connection().begin(lock_type)

    def commit(self):
        self.connection().commit()

    def rollback(self):
        self.connection().rollback()

    def execute_sql(self, sql, params=None, commit=True):
        logger.debug((sql, params))
        with __exception_wrapper__:
            conn = self.connection()
            stmt = conn.execute(sql, params or ())
        return stmt

import logging
logger = logging.getLogger('peewee')
logger.addHandler(logging.StreamHandler())
logger.setLevel(logging.DEBUG)

db = CySqliteDatabase(':memory:')

class Base(Model):
    class Meta:
        database = db

class User(Base):
    username = TextField()
    timestamp = TimestampField()

class Tweet(Base):
    user = ForeignKeyField(User, backref='tweets')
    content = TextField()
    timestamp = TimestampField()

@db.func('md5')
def hash_fn(s):
    if isinstance(s, str):
        s = s.encode('utf8')
    return hashlib.md5(s).hexdigest()


db.create_tables([User, Tweet])

with db.atomic() as tx:
    u1 = User.create(username='u1')
    u2 = User.create(username='u2')
    with db.atomic() as sp1:
        u3 = User.create(username='u3')
        sp1.rollback()
    with db.atomic() as sp2:
        for i in range(4):
            Tweet.create(user=u1, content='u1-t%d' % i)

query = User.select().order_by(User.username)
assert [u.username for u in query] == ['u1', 'u2']

query = Tweet.select(Tweet, User, fn.md5(User.username).alias('hsh')).join(User).order_by(User.username, Tweet.id)
for tweet in query:
    print(tweet.user.username, tweet.timestamp, tweet.content, tweet.hsh)
