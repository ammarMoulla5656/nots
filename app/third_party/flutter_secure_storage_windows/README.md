# flutter_secure_storage_windows 4.2.2, without its C++ part

The package keeps values in Dart (DPAPI, through FFI). Its C++ plugin is the
older storage, kept only to read values saved by old versions, and it needs
Visual Studio's ATL component to build. This app never used that older
storage, so dropping it lets the Windows app build without ATL.

The Dart part still calls the old channel for such values: `_NoOldStorage` in
`lib/src/flutter_secure_storage_windows_ffi.dart` answers "nothing there"
instead. That is the only change to the Dart code.
