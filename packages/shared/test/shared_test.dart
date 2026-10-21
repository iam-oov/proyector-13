import 'package:flutter_test/flutter_test.dart';
import 'package:shared/shared.dart';

void main() {
  // Caso real del 2026-10-20: lo que sonaba en Spotify y lo que devolvió YouTube.
  const track = Track(title: 'Hablando Claro - En Vivo', artists: ['Grupo Firme', 'Grupo Recluta']);
  const videos = [
    VideoCandidate(id: 'g2BzGJnNvEw', title: 'Grupo Firme -  Ya Superame - (Video Oficial)', channel: 'Grupo Firme'),
    VideoCandidate(id: '01A5LyKvG0c', title: 'Grupo Firme - Grupo Recluta - Hablando Claro  (Video Oficial)', channel: 'Grupo Firme'),
    VideoCandidate(id: 'MomxRUGRUB4', title: 'Grupo Firme x Grupo Recluta - Hablando Claro [Official Video]', channel: 'RB Music'),
    VideoCandidate(id: 'ejT1av36oKM', title: 'Grupo Firme - Grupo Recluta - Hablando Claro ( Video Lyrics )', channel: 'MUSIC VIP'),
    VideoCandidate(id: 'lapbBBrOHLo', title: 'Hablando Claro - Grupo Firme (Live Session)', channel: 'Music Heaven'),
  ];

  test('baseTitle quita sufijos de versión', () {
    expect(baseTitle('Hablando Claro - En Vivo'), 'hablando claro');
    expect(baseTitle('Ya Supérame (En Vivo)'), 'ya superame');
    expect(baseTitle('Canción [Remastered 2020]'), 'cancion');
  });

  test('searchQuery usa solo el primer artista', () {
    expect(track.searchQuery, 'Grupo Firme Hablando Claro - En Vivo official video');
  });

  test('gana el video oficial del artista con el título correcto', () {
    final ranked = rankVideos(videos, track);
    expect(ranked.first.video.id, '01A5LyKvG0c');
    // La otra canción del mismo canal ya no empata: le falta el título.
    expect(ranked.first.score, greaterThan(ranked[1].score));
  });

  test('lyrics, covers y lives quedan al final', () {
    final ids = rankVideos(videos, track).map((r) => r.video.id).toList();
    expect(ids.indexOf('ejT1av36oKM'), greaterThan(ids.indexOf('MomxRUGRUB4')));
    expect(ids.last, isIn(['ejT1av36oKM', 'lapbBBrOHLo']));
  });
}
