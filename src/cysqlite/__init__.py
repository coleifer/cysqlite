from cysqlite._cysqlite import *
from cysqlite._constants import *
from cysqlite.exceptions import *


version = __version__ = '0.4.1'
version_info = tuple(int(i) for i in version.split('.'))

# DB-API 2.0 module attributes.
apilevel = '2.0'
paramstyle = 'qmark'

Binary = memoryview
