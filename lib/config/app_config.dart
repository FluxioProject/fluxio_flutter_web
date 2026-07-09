class AppConfig {
  static const apiBaseUrl = String.fromEnvironment(
    'FLUXIO_API_BASE_URL',
    defaultValue: 'https://us-central1-tcc2026-7d3c4.cloudfunctions.net/api',
  );

  static const apiKey = String.fromEnvironment('FLUXIO_API_KEY');
}
