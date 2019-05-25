import glob
import os
import sys
import unittest

from cysqlite import *


class BaseTestCase(unittest.TestCase):
    filename = '/tmp/cysqlite.db'
    pattern = filename + '*'

    def cleanup(self):
        if self.filename != ':memory:':
            for filename in glob.glob(self.pattern):
                if os.path.isfile(filename):
                    os.unlink(filename)

    def setUp(self):
        self.db = Connection(self.filename)
        self.db.connect()

    def tearDown(self):
        if not self.db.is_closed():
            self.db.close()
        self.cleanup()


class TestQueryExecution(BaseTestCase):
    filename = ':memory:'

    def create_table(self):
        self.db.execute('create table "kv" ("id" integer not null primary key,'
                        ' "key" text not null, "value" text not null, "extra" '
                        'integer)')

    def create_rows(self, *rows):
        for row in rows:
            self.db.execute('insert into "kv" ("key", "value", "extra") '
                            'values (?, ?, ?)', row)

    def test_simple_query(self):
        self.create_table()
        self.create_rows(('k1', 'v1', 1), ('k2', 'v2', 20), ('k3', 'v3', 3))
        self.assertEqual(self.db.last_insert_rowid(), 3)
        self.assertEqual(self.db.changes(), 1)
        self.assertEqual(self.db.total_changes(), 3)

        with self.db.atomic():
            curs = self.db.execute('select * from kv order by key')
            self.assertEqual(list(curs), [
                (1, 'k1', 'v1', 1),
                (2, 'k2', 'v2', 20),
                (3, 'k3', 'v3', 3)])

    def test_autocommit(self):
        self.assertTrue(self.db.autocommit())
        self.create_table()
        with self.db.atomic() as txn:
            self.assertFalse(self.db.autocommit())
            self.create_rows(('k1', 'v1', 1))
            with self.db.atomic() as txn:
                self.create_rows(('k2', 'v2', 2))
                txn.rollback()
            with self.db.atomic() as txn:
                self.create_rows(('k3', 'v3', 3))
                self.assertFalse(self.db.autocommit())
            self.assertFalse(self.db.autocommit())

        self.assertTrue(self.db.autocommit())
        curs = self.db.execute('select key from kv order by key')
        self.assertEqual([row for row in curs], [('k1',), ('k3',)])


if __name__ == '__main__':
    unittest.main(argv=sys.argv)
