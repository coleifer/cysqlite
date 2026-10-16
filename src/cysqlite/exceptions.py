class SqliteError(Exception):
    # Extended result code, set on errors reported by SQLite.
    sqlite_errorcode: int

class Error(SqliteError): pass
class Warning(SqliteError): pass

class InterfaceError(Error): pass
class DatabaseError(Error): pass

class DataError(DatabaseError): pass
class OperationalError(DatabaseError): pass
class IntegrityError(DatabaseError): pass
class InternalError(DatabaseError): pass
class ProgrammingError(DatabaseError): pass
class NotSupportedError(DatabaseError): pass

# New subclasses - all still IntegrityError for back-compat.
class UniqueIntegrityError(IntegrityError): pass
class NotNullIntegrityError(IntegrityError): pass
class ForeignKeyIntegrityError(IntegrityError): pass
class CheckIntegrityError(IntegrityError): pass
class PrimaryKeyIntegrityError(IntegrityError): pass

# New subclasses for I/O-flavored OperationalErrors.
class DiskFullError(OperationalError): pass
class ReadOnlyError(OperationalError): pass
class DatabaseLockedError(OperationalError): pass
class AuthorizationError(OperationalError): pass

# For database-integrity problems that aren't constraint violations.
class DatabaseCorruptError(DatabaseError): pass
