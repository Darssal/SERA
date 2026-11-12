import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast_io.dart';

Future<Database> openWorkspaceDatabase(String name) async {
  final directory = await getApplicationSupportDirectory();
  await directory.create(recursive: true);
  return databaseFactoryIo.openDatabase('${directory.path}/$name.db');
}

Future<void> deleteWorkspaceDatabase(String name) async {
  final directory = await getApplicationSupportDirectory();
  await databaseFactoryIo.deleteDatabase('${directory.path}/$name.db');
}
