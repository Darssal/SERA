import 'package:dio/dio.dart';
import 'package:dio/browser.dart';

void configureCredentials(Dio client) {
  client.httpClientAdapter = BrowserHttpClientAdapter(withCredentials: true);
}
