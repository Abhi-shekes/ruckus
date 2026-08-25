# libFLAC.so.14 for glibc < 2.34

flutter_soloud ships a prebuilt `libFLAC.so.14` linked against **glibc 2.34**.
Ubuntu 20.04 has glibc 2.31, so `libflutter_soloud_plugin.so` fails to load
there with:

    /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.33' not found
    (required by .../flutter_soloud/linux/libs/libFLAC.so.14)

Every other bundled lib (ogg, opus, vorbis, vorbisfile) is fine — libFLAC is
the only one over the line.

This copy is FLAC 1.5.0 built from source on 20.04, configured `-DWITH_OGG=OFF`
(the plugin only calls the native stream decoder, never the OGG-FLAC variants),
so it needs no more than glibc 2.29 while keeping the `libFLAC.so.14` soname.

`run.sh` puts this directory on `LD_LIBRARY_PATH`, which the loader consults
*before* the plugin's RUNPATH — so nothing in the pub cache is modified.

**On Ubuntu 22.04+ this is unnecessary.** The stock plugin loads fine there,
which is a further reason to target 22.04+ as PLAN.md already recommends.

## libsqlite3.so

`sqflite_common_ffi` calls `DynamicLibrary.open('libsqlite3.so')` — the
unversioned name, which on Debian/Ubuntu only exists if `libsqlite3-dev` is
installed. The runtime package ships `libsqlite3.so.0` alone, so the database
fails to open on a stock system with:

    Failed to load dynamic library 'libsqlite3.so': cannot open shared object file

The symlink here supplies the unversioned name from the same
`LD_LIBRARY_PATH` entry as libFLAC. `sudo apt install libsqlite3-dev` is the
other way to fix it, but this keeps the app runnable without root.
