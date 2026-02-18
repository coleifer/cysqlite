# cython: language_level=3
from cpython.buffer cimport PyBUF_SIMPLE
from cpython.buffer cimport PyObject_CheckBuffer
from cpython.buffer cimport PyObject_GetBuffer
from cpython.buffer cimport PyBuffer_Release
from cpython.buffer cimport Py_buffer
from cpython.bytes cimport PyBytes_Check
from cpython.bytes cimport PyBytes_AS_STRING
from cpython.bytes cimport PyBytes_GET_SIZE
from cpython.unicode cimport PyUnicode_Check
from cpython.unicode cimport PyUnicode_AsUTF8String
from cpython.unicode cimport PyUnicode_DecodeUTF8


cdef inline unicode decode(key):
    if PyBytes_Check(key):
        return PyUnicode_DecodeUTF8(
            PyBytes_AS_STRING(key),
            PyBytes_GET_SIZE(key),
            NULL)
    elif PyUnicode_Check(key):
        return <unicode>key
    elif key is None:
        return None

    cdef Py_buffer view

    if PyObject_CheckBuffer(key):
        PyObject_GetBuffer(key, &view, PyBUF_SIMPLE)
        try:
            return PyUnicode_DecodeUTF8(<const char*>view.buf, view.len, NULL)
        finally:
            PyBuffer_Release(&view)

    cdef unicode ukey = str(key)
    return PyUnicode_DecodeUTF8(
        PyBytes_AS_STRING(PyUnicode_AsUTF8String(ukey)),
        PyBytes_GET_SIZE(PyUnicode_AsUTF8String(ukey)),
        NULL)


cdef inline bytes encode(key):
    if PyUnicode_Check(key):
        return PyUnicode_AsUTF8String(key)
    elif PyBytes_Check(key):
        return <bytes>key
    elif key is None:
        return None

    cdef Py_buffer view

    if PyObject_CheckBuffer(key):
        PyObject_GetBuffer(key, &view, PyBUF_SIMPLE)
        try:
            return PyBytes_AS_STRING((<char*>view.buf))[:view.len]
        finally:
            PyBuffer_Release(&view)

    return PyUnicode_AsUTF8String(str(key))
