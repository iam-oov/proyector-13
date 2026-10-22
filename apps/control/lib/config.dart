/// Valores que se inyectan al compilar con `--dart-define-from-file=../../.env`.
/// Las keys nunca van en el código. La pantalla a la que se manda ya no viene
/// de aquí: se guarda al escanear su QR (ver screens.dart).
class Config {
  static const spotifyClientId = String.fromEnvironment('SPOTIFY_CLIENT_ID');
  static const spotifyRedirectUri = String.fromEnvironment(
    'SPOTIFY_REDIRECT_URI',
    defaultValue: 'http://127.0.0.1:8888/callback',
  );
  static const youtubeApiKey = String.fromEnvironment('YOUTUBE_API_KEY');

  /// Asistente de voz (Claude Haiku). Queda dentro del APK: usar una key propia
  /// con límite de gasto en la consola de Anthropic.
  static const anthropicApiKey = String.fromEnvironment('ANTHROPIC_API_KEY');

  static bool get hasSpotify => spotifyClientId.isNotEmpty;
  static bool get hasYouTube => youtubeApiKey.isNotEmpty;
  static bool get hasAssistant => anthropicApiKey.isNotEmpty;
  static bool get isComplete => hasSpotify && hasYouTube;
}
