# cython: language_level=3
from cpython.bytes cimport PyBytes_Check
from cpython.unicode cimport PyUnicode_AsUTF8String
from cpython.unicode cimport PyUnicode_Check


cdef inline unicode decode(key):
    cdef unicode ukey
    if PyBytes_Check(key):
        ukey = key.decode('utf-8')
    elif PyUnicode_Check(key):
        ukey = <unicode>key
    elif key is None:
        return None
    else:
        ukey = unicode(key)
    return ukey


cdef inline bytes encode(key):
    cdef bytes bkey
    if PyUnicode_Check(key):
        bkey = PyUnicode_AsUTF8String(key)
    elif PyBytes_Check(key):
        bkey = <bytes>key
    elif key is None:
        return None
    else:
        bkey = PyUnicode_AsUTF8String(unicode(key))
    return bkey
