import 'package:flutter/material.dart';

/// The colours of the Al-Hikmeh family: the royal blue of the Masdar app,
/// the gold of its spines, and the warm paper of a printed book. By night the
/// paper becomes deep navy and the blue a little lighter, so text and
/// buttons stay clear on it.
abstract final class Brand {
  /// The night look is on. Set by the app when the setting changes (see
  /// AppSettings), and read as the screens are built.
  static bool dark = false;

  static const _blueLight = Color(0xFF1C4F92);
  static const _blueNight = Color(0xFF3D7FD6);

  /// The main blue: buttons, selected things, links.
  static Color get blue => dark ? _blueNight : _blueLight;
  static const blueDeep = Color(0xFF123A70);
  static const blueNight = Color(0xFF0B2346);
  static const gold = Color(0xFFC29A45);
  static const goldLight = Color(0xFFEAD9AE);
  static const green = Color(0xFF1E8A5A);
  static const red = Color(0xFFC8372D);

  /// Page and screen background.
  static Color get paper => dark ? const Color(0xFF0E1626) : const Color(0xFFFBF8F1);

  /// What a page rests on, on a tablet.
  static Color get desk => dark ? const Color(0xFF0A101C) : const Color(0xFFEDE7DA);

  /// Cards and fields.
  static Color get surface => dark ? const Color(0xFF16223A) : Colors.white;
  static Color get ink => dark ? const Color(0xFFE8EDF5) : const Color(0xFF16233A);
  static Color get muted => dark ? const Color(0xFF93A1B8) : const Color(0xFF67748A);
  static Color get line => dark ? const Color(0xFF26334A) : const Color(0xFFE6DFD0);

  /// A pale blue ground (selected rows, tags).
  static Color get tint => dark ? const Color(0xFF1B2B45) : const Color(0xFFE7EFF9);

  /// Text on [tint].
  static Color get onTint => dark ? const Color(0xFFBBD3F2) : blueDeep;

  /// A faint veil over a surface (the track of a segmented control).
  static Color get wash => dark ? const Color(0x14FFFFFF) : const Color(0x0F16233A);

  /// The header gradient of the main screens.
  static LinearGradient get heroGradient => LinearGradient(
    begin: const Alignment(-0.4, -1),
    end: const Alignment(0.4, 1),
    colors: dark
        ? const [Color(0xFF173A6E), Color(0xFF0E2A55), Color(0xFF08142B)]
        : const [Color(0xFF2159A3), blueDeep, blueNight],
    stops: const [0, 0.62, 1],
  );

  static const font = 'Muna';
}

ThemeData buildTheme() {
  final dark = Brand.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: Brand.blue,
        brightness: dark ? Brightness.dark : Brightness.light,
      ).copyWith(
        primary: Brand.blue,
        onPrimary: Colors.white,
        primaryContainer: Brand.tint,
        onPrimaryContainer: Brand.onTint,
        secondary: Brand.gold,
        secondaryContainer: Brand.tint,
        onSecondaryContainer: Brand.onTint,
        tertiary: Brand.green,
        error: Brand.red,
        surface: Brand.paper,
        onSurface: Brand.ink,
        onSurfaceVariant: Brand.muted,
        surfaceContainerLowest: Brand.surface,
        surfaceContainerLow: Brand.surface,
        surfaceContainer: Brand.surface,
        surfaceContainerHigh: Brand.surface,
        surfaceContainerHighest: dark ? const Color(0xFF1E2C47) : const Color(0xFFF1ECDF),
        outline: dark ? const Color(0xFF3A4A66) : const Color(0xFFC9C1AE),
        outlineVariant: Brand.line,
      );
  final base = ThemeData(
    useMaterial3: true,
    brightness: dark ? Brightness.dark : Brightness.light,
    colorScheme: scheme,
    fontFamily: Brand.font,
    scaffoldBackgroundColor: Brand.paper,
    splashFactory: InkSparkle.splashFactory,
  );
  final shadow = dark ? const Color(0x66000000) : const Color(0x1416233A);
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: Brand.ink,
      displayColor: Brand.ink,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: Brand.ink,
      titleTextStyle: TextStyle(
        fontFamily: Brand.font,
        fontSize: 20,
        fontWeight: FontWeight.w900,
        color: Brand.ink,
      ),
    ),
    cardTheme: CardThemeData(
      color: Brand.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      surfaceTintColor: Colors.transparent,
      shadowColor: shadow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Brand.paper,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      titleTextStyle: TextStyle(
        fontFamily: Brand.font,
        fontSize: 19,
        fontWeight: FontWeight.w900,
        color: Brand.ink,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: Brand.paper,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: Brand.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFF22324F) : Brand.blueNight,
      contentTextStyle: const TextStyle(
        fontFamily: Brand.font,
        color: Colors.white,
        fontSize: 14,
      ),
      actionTextColor: Brand.goldLight,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Brand.blue,
        foregroundColor: Colors.white,
        minimumSize: const Size(64, 48),
        textStyle: const TextStyle(
          fontFamily: Brand.font,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Brand.blue,
        textStyle: const TextStyle(
          fontFamily: Brand.font,
          fontWeight: FontWeight.w700,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: Brand.blue,
      textColor: Brand.ink,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
    ),
    dividerTheme: DividerThemeData(color: Brand.line, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Brand.surface,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Brand.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Brand.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Brand.blue, width: 1.6),
      ),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Brand.blue : Brand.line,
      ),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: Brand.blue,
      thumbColor: Brand.blue,
      inactiveTrackColor: Brand.line,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: Brand.blue,
      linearTrackColor: Brand.line,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF22324F) : Brand.blueNight,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(
        fontFamily: Brand.font,
        color: Colors.white,
        fontSize: 12,
      ),
    ),
  );
}
