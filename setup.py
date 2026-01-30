import os
import sys
import warnings

from setuptools import setup
from setuptools.extension import Extension
try:
    from Cython.Build import cythonize
    cython_installed = True
except ImportError:
    cython_installed = False

if cython_installed:
    sources = ['src/cysqlite.pyx']
else:
    sources = ['src/cysqlite.c']
    cythonize = lambda obj: obj

if os.path.exists('src/sqlite3.c') and os.path.exists('src/sqlite3.h'):
    sources.append('src/sqlite3.c')
    include_dirs = ['src/']
    libraries = []
    define_macros = [
        ('SQLITE_ALLOW_COVERING_INDEX_SCAN', 1),
        ('SQLITE_ENABLE_FTS3', 1),
        ('SQLITE_ENABLE_FTS3_PARENTHESIS', 1),
        ('SQLITE_ENABLE_FTS4', 1),
        ('SQLITE_ENABLE_FTS5', 1),
        ('SQLITE_ENABLE_JSON1', 1),
        ('SQLITE_ENABLE_LOAD_EXTENSION', 1),
        ('SQLITE_ENABLE_MATH_FUNCTIONS', 1),
        ('SQLITE_ENABLE_RTREE', 1),
        ('SQLITE_ENABLE_STAT4', 1),
        ('SQLITE_ENABLE_UPDATE_DELETE_LIMIT', 1),
        ('SQLITE_SOUNDEX', 1),
        ('SQLITE_USE_URI', 1),
        ('SQLITE_TEMP_STORE', 3),
        ('SQLITE_MAX_VARIABLE_NUMBER', 250000),
        ('SQLITE_MAX_MMAP_SIZE', 2**40),
    ]
else:
    include_dirs = []
    libraries = ['sqlite3']
    define_macros = []

compile_args = ['-O3', '-Wall'] if sys.platform != 'win32' else ['/O2']

cysqlite_extension = Extension(
    'cysqlite',
    sources=sources,
    include_dirs=include_dirs,
    libraries=libraries,
    define_macros=define_macros,
    extra_compile_args=compile_args)

setup(ext_modules=cythonize([cysqlite_extension]))
