import 'package:sembast_web/sembast_web.dart';

Future<Database> openWorkspaceDatabase(String name) =>
    databaseFactoryWeb.openDatabase(name);

Future<void> deleteWorkspaceDatabase(String name) =>
    databaseFactoryWeb.deleteDatabase(name);
