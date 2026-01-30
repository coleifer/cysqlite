import hashlib

from cysqlite import Connection
from cysqlite import TableFunction

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
        for name, (fn, num_params, deterministic) in self._functions.items():
            conn.create_function(fn, name, num_params, deterministic)

    def _load_window_functions(self, conn):
        for name, (klass, num_params) in self._window_functions.items():
            conn.create_window_function(klass, name, num_params)

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

    def execute_sql(self, sql, params=None):
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
        try:
            with db.atomic() as sp3:
                Tweet.create(user=u2, content='u2-t1')
                raise ValueError('asdf')
        except ValueError:
            pass

with db.atomic() as tx:
    u3 = User.create(username='u3')
    u4 = User.create(username='u4')
    tx.rollback()
    try:
        Tweet.create(user=u3, content='u2-1')
    except IntegrityError:
        pass
    Tweet.create(user=u2, content='u2-1')

query = User.select().order_by(User.username)
assert [u.username for u in query] == ['u1', 'u2']

query = Tweet.select(Tweet, User, fn.md5(User.username).alias('hsh')).join(User).order_by(User.username, Tweet.id)
for tweet in query:
    print(tweet.user.username, tweet.timestamp, tweet.content, tweet.hsh)

@db.table_function('series')
class Series(TableFunction):
    columns = ['value']
    params = ['start', 'stop', 'step']
    name = 'series'

    def initialize(self, start=0, stop=None, step=1):
        self.start = start
        self.stop = stop or float('inf')
        self.step = step
        self.curr = self.start

    def iterate(self, idx):
        if self.curr > self.stop:
            raise StopIteration

        ret = self.curr
        self.curr += self.step
        return (ret,)

logger.setLevel(logging.INFO)

for i in range(10):
    db.close()
    db.connect()
    accum = [row[0] for row in db.execute_sql('select * from series(1, 10)')]
    assert accum == list(range(1, 11))

#db.create_tables([User, Tweet])
