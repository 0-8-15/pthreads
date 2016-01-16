# pthreads

Maintain and talk to a pthread pool.

# Issues

* Requires recent chicken

* Starts currently 5 pthreads.  TBD: make this configurable and start as
many threads a the operating system configured processors are
available.

# API

### (pool-send! JOB DATA CALLBACK) -> undefined

All arguments given as `non-null-c-pointer`.

JOB: The C procedure to all

DATA: Opaque ppointer for parameter passing.

CALLBACK: Pointer to callback procedure.  Typically a `C_GC_ROOT`.

# Author

Jörg F. Wittenberger

# License

BSD
