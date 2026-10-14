/// Override per build: `flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3000`
const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://api-production-7e8d.up.railway.app',
);
