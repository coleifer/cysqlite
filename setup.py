import glob
import warnings

from setuptools import setup
from setuptools.extension import Extension
try:
    from Cython.Build import cythonize
except ImportError:
    cython_installed = False
    warnings.warn('Cython not installed, using pre-generated C source file.')
else:
    cython_installed = True


if cython_installed:
    python_sources = glob.glob('src/*.pyx')
else:
    python_sources = glob.glob('src/*.c')
    cythonize = lambda obj: obj

cysqlite_extension = Extension('cysqlite', libraries=['sqlite3'],
                               sources=python_sources)

setup(
    name='cysqlite',
    version='0.1.0',
    description='',
    author='Charles Leifer',
    author_email='',
    url='https://github.com/coleifer',
    license='MIT',
    install_requires=['Cython'],
    setup_requires=['cython'],
    ext_modules=cythonize([cysqlite_extension])
)
