import 'package:flutter/material.dart';

class TeamPalette {
  const TeamPalette({
    required this.primary,
    required this.secondary,
    required this.accent,
    required this.darkBase,
    required this.lightBase,
    required this.onColor,
  });

  final Color primary;
  final Color secondary;
  final Color accent;
  final Color darkBase;
  final Color lightBase;
  final Color onColor;

  List<Color> background(Brightness brightness) {
    if (brightness == Brightness.light) {
      return <Color>[lightBase, secondary, Colors.white];
    }
    return <Color>[primary, secondary, darkBase];
  }

  Color foreground(Brightness brightness) {
    return brightness == Brightness.dark ? onColor : Colors.black;
  }
}

class TeamColors {
  static final TeamPalette red = TeamPalette(
    primary: Colors.red.shade900,
    secondary: Colors.red.shade300,
    accent: Colors.redAccent,
    darkBase: Colors.black,
    lightBase: Colors.red.shade100,
    onColor: Colors.white,
  );

  static final TeamPalette blue = TeamPalette(
    primary: Colors.indigo.shade900,
    secondary: Colors.blue.shade300,
    accent: Colors.lightBlueAccent,
    darkBase: Colors.black,
    lightBase: Colors.blue.shade100,
    onColor: Colors.white,
  );

  static final TeamPalette green = TeamPalette(
    primary: Colors.green.shade900,
    secondary: Colors.teal.shade300,
    accent: Colors.greenAccent,
    darkBase: Colors.black,
    lightBase: Colors.green.shade100,
    onColor: Colors.white,
  );

  static final TeamPalette yellow = TeamPalette(
    primary: Colors.orange.shade900,
    secondary: Colors.amber.shade700,
    accent: Colors.amberAccent,
    darkBase: Colors.black,
    lightBase: Colors.amber.shade100,
    onColor: Colors.black,
  );

  static final TeamPalette neutral = TeamPalette(
    primary: Colors.grey.shade900,
    secondary: Colors.blueGrey.shade300,
    accent: Colors.white,
    darkBase: Colors.black,
    lightBase: Colors.grey.shade200,
    onColor: Colors.white,
  );
}

TeamPalette teamPaletteFor(String team) {
  final normalized = team.toLowerCase();
  if (normalized.contains('red')) {
    return TeamColors.red;
  }
  if (normalized.contains('blue')) {
    return TeamColors.blue;
  }
  if (normalized.contains('green')) {
    return TeamColors.green;
  }
  if (normalized.contains('yellow')) {
    return TeamColors.yellow;
  }
  return TeamColors.neutral;
}
