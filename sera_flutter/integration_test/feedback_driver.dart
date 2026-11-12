import 'package:integration_test/integration_test_driver.dart';

// Host entrypoint for flutter drive, not the app/test --target.
// Performance samples must be collected by the target and sent in reportData.
Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) =>
      writeResponseData(data, testOutputFilename: 'feedback-profile-response'),
);
