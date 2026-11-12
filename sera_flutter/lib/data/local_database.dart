import 'local_database_native.dart'
    if (dart.library.js_interop) 'local_database_web.dart'
    as implementation;

import 'package:sembast/sembast.dart';

Future<Database> openWorkspaceDatabase(String name) =>
    implementation.openWorkspaceDatabase(name);

Future<void> deleteWorkspaceDatabase(String name) =>
    implementation.deleteWorkspaceDatabase(name);
