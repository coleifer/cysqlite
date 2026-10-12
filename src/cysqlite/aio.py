import asyncio
import queue
import threading
from collections import deque
from functools import partial
from cysqlite._cysqlite import connect as _connect
from cysqlite._cysqlite import Connection
from cysqlite._cysqlite import Row
from cysqlite.exceptions import InterfaceError
from cysqlite.exceptions import OperationalError
from cysqlite.utils import _ConnectionContext
from cysqlite.utils import Pool as _Pool


SHUTDOWN = object()


class AsyncConnection(object):
    def __init__(self, conn, loop):
        self.conn = conn
        self.loop = loop
        self.queue = queue.SimpleQueue()
        self._closed = False
        self._lock = threading.Lock()
        self._running = None  # Future of the job the worker is running.
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def __del__(self):
        thread = getattr(self, '_thread', None)
        if thread is not None and thread.is_alive():
            self.queue.put((partial(self.conn.close, True), None))
            self.queue.put(SHUTDOWN)

    @staticmethod
    def _resolve(fut, exc, result):
        # Runs on the loop thread. The future may have been cancelled while
        # the worker was busy, in which case there is nothing to deliver.
        if fut.done():
            return
        if exc is not None:
            fut.set_exception(exc)
        else:
            fut.set_result(result)

    def _run(self):
        while True:
            item = self.queue.get()
            if item is SHUTDOWN:
                break
            fn, fut = item
            with self._lock:
                self._running = fut
            try:
                result, exc = fn(), None
            except BaseException as e:
                result, exc = None, e
            # Cleared before resolving so a late cancel cannot interrupt the
            # next job.
            with self._lock:
                self._running = None
            if fut is not None:
                self.loop.call_soon_threadsafe(self._resolve, fut, exc, result)

    def _submit(self, fn, *args, **kwargs):
        if self._closed:
            raise OperationalError('Cannot operate on closed database.')
        fut = self.loop.create_future()
        def wrap():
            if not fut.cancelled():
                return fn(*args, **kwargs)
        self.queue.put((wrap, fut))
        return fut

    async def _submit_query(self, fn, *args, **kwargs):
        # Like _submit, but interrupt the query if cancelled while it runs.
        fut = self._submit(fn, *args, **kwargs)
        try:
            return await fut
        except asyncio.CancelledError:
            # A query still in the queue is skipped by the worker, and the
            # running one may belong to another task.
            with self._lock:
                if self._running is fut and not self.conn.is_closed():
                    self.conn.interrupt()
            raise

    async def execute(self, sql, params=None):
        cursor = await self._submit_query(self.conn.execute, sql, params)
        return AsyncCursor(self, cursor)

    async def executemany(self, sql, seq_of_params):
        cursor = await self._submit_query(self.conn.executemany, sql,
                                          seq_of_params)
        return AsyncCursor(self, cursor)

    async def executescript(self, sql):
        cursor = await self._submit_query(self.conn.executescript, sql)
        return AsyncCursor(self, cursor)

    async def execute_one(self, sql, params=None):
        return await self._submit_query(self.conn.execute_one, sql, params)

    async def execute_scalar(self, sql, params=None):
        return await self._submit_query(self.conn.execute_scalar, sql, params)

    async def begin(self, lock=None):
        await self._submit(self.conn.begin, lock=lock)

    async def commit(self):
        await self._submit(self.conn.commit)

    async def rollback(self):
        await self._submit(self.conn.rollback)

    async def close(self):
        if self._closed:
            return False

        # If close fails (e.g. a transaction is open) leave the worker alive
        # so the caller can roll back and retry.
        await self._submit(self.conn.close)
        self._closed = True
        self.queue.put(SHUTDOWN)
        await self.loop.run_in_executor(None, self._thread.join, 5.0)
        if self._thread.is_alive():
            raise RuntimeError('Could not shut down database thread.')
        return True

    async def last_insert_rowid(self):
        return await self._submit(self.conn.last_insert_rowid)

    async def changes(self):
        return await self._submit(self.conn.changes)

    async def backup(self, dest, **kwargs):
        await self._submit(self.conn.backup, dest.conn, **kwargs)

    async def backup_to_file(self, filename, **kwargs):
        await self._submit(self.conn.backup_to_file, filename, **kwargs)

    async def checkpoint(self, **kwargs):
        return await self._submit(self.conn.checkpoint, **kwargs)

    def transaction(self, lock=None):
        return AsyncTransaction(self, lock)

    def savepoint(self, sid=None):
        return AsyncSavepoint(self, sid)

    def atomic(self, lock=None):
        return AsyncAtomic(self, lock)

    @property
    def in_transaction(self):
        return self.conn.in_transaction

    def pragma(self, *args, **kwargs):
        return self._submit(self.conn.pragma, *args, **kwargs)

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        await self.close()


class AsyncCursor:
    def __init__(self, conn, cursor):
        self.conn = conn
        self._cursor = cursor
        self._buffer = []

    async def fetchone(self):
        return await self.conn._submit(self._cursor.fetchone)

    async def fetchall(self):
        return await self.conn._submit(self._cursor.fetchall)

    async def scalar(self):
        return await self.conn._submit(self._cursor.scalar)

    @property
    def description(self):
        return self._cursor.description

    @property
    def lastrowid(self):
        return self._cursor.lastrowid

    @property
    def rowcount(self):
        return self._cursor.rowcount

    async def fetchmany(self, size=100, constructor=None):
        def _fetch():
            res = self._cursor.fetchmany(size)
            if constructor is not None:
                res = constructor(res)
            return res
        return await self.conn._submit(_fetch)

    def __aiter__(self):
        return self

    async def __anext__(self):
        # Use internal buffer to amortize dispatch cost.
        if not self._buffer:
            self._buffer = await self.fetchmany(100, deque)
            if not self._buffer:
                raise StopAsyncIteration
        return self._buffer.popleft()

    async def close(self):
        if self._cursor is not None:
            cursor, self._cursor = self._cursor, None
            await self.conn._submit(cursor.close)


class _AsyncTransactionWrapper(object):
    def __init__(self, conn, *args):
        self.conn = conn
        self._sync_conn = conn.conn
        self._args = args

    def get_wrapper(self):
        raise NotImplementedError

    async def __aenter__(self):
        self._txn = self.get_wrapper()
        await self.conn._submit(self._txn.__enter__)
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        await self.conn._submit(partial(self._txn.__exit__, exc_type, exc_val,
                                        exc_tb))

    async def commit(self, *args):
        await self.conn._submit(partial(self._txn.commit, *args))

    async def rollback(self, *args):
        await self.conn._submit(partial(self._txn.rollback, *args))


class AsyncTransaction(_AsyncTransactionWrapper):
    def get_wrapper(self):
        return self._sync_conn.transaction(*self._args)

class AsyncSavepoint(_AsyncTransactionWrapper):
    def get_wrapper(self):
        return self._sync_conn.savepoint(*self._args)

class AsyncAtomic(_AsyncTransactionWrapper):
    def get_wrapper(self):
        return self._sync_conn.atomic(*self._args)


def connect(database, **kwargs):
    loop = asyncio.get_running_loop()
    conn = _connect(database, **kwargs)
    return AsyncConnection(conn, loop=loop)


class Pool(_Pool):
    def initialize_pool(self, readers, writer):
        self._loop = asyncio.get_running_loop()
        self._readers = asyncio.Queue()
        self._writer_lock = asyncio.Lock()
        self._writer = None

        if writer:
            self._writer = AsyncConnection(
                self._connect(read_only=False),
                loop=self._loop)

        for _ in range(readers):
            self._readers.put_nowait(AsyncConnection(
                self._connect(read_only=True),
                loop=self._loop))

    def reader(self):
        self._check_closed()
        return _AsyncReader(self)

    def writer(self):
        self._check_closed()
        if self._writer is None:
            raise InterfaceError('Pool writer connection disabled.')
        return _AsyncWriter(self)

    async def close(self):
        self._closed = True
        if self._writer is not None:
            # Wait for the writer to be returned if it is checked out.
            async with self._writer_lock:
                await self._writer.close()
                self._writer = None
        while not self._readers.empty():
            await self._readers.get_nowait().close()


class _AsyncReader(_ConnectionContext):
    async def __aenter__(self):
        self.conn = await self.pool._readers.get()
        return self.conn

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        if self.conn is not None:
            try:
                if self.conn.in_transaction:
                    await self.conn.rollback()
            finally:
                if self.pool._closed:
                    await self.conn.close()
                else:
                    await self.pool._readers.put(self.conn)
                self.conn = None

class _AsyncWriter(_ConnectionContext):
    async def __aenter__(self):
        await self.pool._writer_lock.acquire()
        self.conn = self.pool._writer
        return self.conn

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        try:
            if self.conn.in_transaction:
                await self.conn.rollback()
        finally:
            self.conn = None
            self.pool._writer_lock.release()
