# mediaremote-adapter (vendored)

From https://github.com/ungive/mediaremote-adapter at commit `0e82bf1c44ec39554fbfc402ec88a48c6ae2a0fd`
(BSD 3-Clause, see `LICENSE`). Only the adapter framework sources and the Perl script are kept;
the test client (except the header `src/adapter/test.m` needs) and CMake files are left out.

macOS 15.4+ only lets entitled processes read MediaRemote's now-playing info. `/usr/bin/perl` is one,
so `bin/mediaremote-adapter.pl` loads the adapter library into Perl and streams JSON to stdout.
`scripts/build-app.sh` compiles the library with clang into
`BK Light.app/Contents/Resources/MediaRemoteAdapter.framework/MediaRemoteAdapter`.
