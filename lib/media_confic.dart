class MediaConfic {
  MediaConfic._();

  static const String audioBasePath = 'media/audio';

  static const String laserShot = '$audioBasePath/laser_shot.mp3';
  static const String shootingShort = '$audioBasePath/shootingshort.mp3';
  static const String gunShot = '$audioBasePath/gunshot_2.mp3';
  static const String reload = '$audioBasePath/reload.mp3';
  static const String beep = '$audioBasePath/beep.mp3';
  static const String score = '$audioBasePath/score.mp3';
  static const String eliminated = '$audioBasePath/eliminated.mp3';
  static const String spawn = '$audioBasePath/spawn.mp3';
  static const String empty = '$audioBasePath/empty.mp3';
  static const String healUp = '$audioBasePath/heal-up.mp3';
  static const String shield = '$audioBasePath/shield.mp3';
  static const String bombDropping = '$audioBasePath/bomb-dropping.mp3';
  static const String explosion = '$audioBasePath/explosion.mp3';

  static const List<String> gunShotCandidates = <String>[
    shootingShort,
    gunShot,
    laserShot,
  ];

  static const List<String> reloadCandidates = <String>[reload];

  static const List<String> modeCandidates = <String>[beep];

  static const List<String> hitCandidates = <String>[score, eliminated];

  static const List<String> recoilEnabledCandidates = <String>[spawn, beep];

  static const List<String> recoilDisabledCandidates = <String>[empty, beep];

  static const List<String> connectCandidates = <String>[spawn];

  static const List<String> disconnectCandidates = <String>[eliminated];

  static const List<String> healCandidates = <String>[healUp];

  static const List<String> shieldCandidates = <String>[shield];

  static String bundlePath(String assetPath) => 'assets/$assetPath';
}
