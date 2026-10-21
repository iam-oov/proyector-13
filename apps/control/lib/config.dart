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

  static bool get hasSpotify => spotifyClientId.isNotEmpty;
  static bool get hasYouTube => youtubeApiKey.isNotEmpty;
  static bool get isComplete => hasSpotify && hasYouTube;
}
