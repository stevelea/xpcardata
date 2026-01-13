import 'package:flutter/material.dart';

/// App theme modes
enum AppThemeMode {
  light,
  dark,
  system,
  xpeng,
}

/// Extension to get display name and icon for theme modes
extension AppThemeModeExtension on AppThemeMode {
  String get displayName {
    switch (this) {
      case AppThemeMode.light:
        return 'Light';
      case AppThemeMode.dark:
        return 'Dark';
      case AppThemeMode.system:
        return 'System';
      case AppThemeMode.xpeng:
        return 'XPENG';
    }
  }

  IconData get icon {
    switch (this) {
      case AppThemeMode.light:
        return Icons.light_mode;
      case AppThemeMode.dark:
        return Icons.dark_mode;
      case AppThemeMode.system:
        return Icons.brightness_auto;
      case AppThemeMode.xpeng:
        return Icons.electric_car;
    }
  }

  String get description {
    switch (this) {
      case AppThemeMode.light:
        return 'Light background with blue accents';
      case AppThemeMode.dark:
        return 'Dark background, easier on eyes';
      case AppThemeMode.system:
        return 'Follow device settings';
      case AppThemeMode.xpeng:
        return 'Native XPENG look and feel';
    }
  }
}

/// XPENG brand colors - using XPENG blue theme
class XPengColors {
  // Primary accent - XPENG blue (sleek automotive blue)
  static const Color primary = Color(0xFF1E88E5);       // Main blue
  static const Color primaryLight = Color(0xFF42A5F5);  // Lighter blue
  static const Color primaryDark = Color(0xFF1565C0);   // Darker blue

  // Secondary accent - green used for active/climate controls
  static const Color accentGreen = Color(0xFF4CAF50);
  static const Color accentGreenLight = Color(0xFF6FBF73);
  static const Color accentGreenDark = Color(0xFF388E3C);

  // Background colors - light theme (settings screen style)
  static const Color backgroundLight = Color(0xFFF5F7FA);  // Cool gray-white
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color cardLight = Color(0xFFFFFFFF);

  // Background colors - dark theme (climate screen style)
  static const Color backgroundDark = Color(0xFF121212);
  static const Color surfaceDark = Color(0xFF1E1E1E);
  static const Color cardDark = Color(0xFF2D2D2D);

  // Text colors
  static const Color textPrimaryLight = Color(0xFF1A1A1A);
  static const Color textSecondaryLight = Color(0xFF666666);
  static const Color textTertiaryLight = Color(0xFF999999);

  // Transparent variants for containers (pre-computed)
  static const Color primaryLight20 = Color(0x3342A5F5);  // 20% opacity
  static const Color accentGreenLight20 = Color(0x336FBF73);
  static const Color info20 = Color(0x332196F3);
  static const Color error20 = Color(0x33E53935);
  static const Color textTertiaryLight50 = Color(0x80999999);
  static const Color primary50 = Color(0x801E88E5);       // 50% opacity
  static const Color textTertiaryLight30 = Color(0x4D999999);
  static const Color primary20 = Color(0x331E88E5);       // 20% opacity

  // Dark theme transparent variants
  static const Color primaryDark30 = Color(0x4D1565C0);
  static const Color accentGreenDark30 = Color(0x4D388E3C);
  static const Color info30 = Color(0x4D2196F3);
  static const Color error30 = Color(0x4DE53935);
  static const Color textTertiaryDark50 = Color(0x80808080);
  static const Color textTertiaryDark30 = Color(0x4D808080);
  static const Color textTertiaryDark20 = Color(0x33808080);

  static const Color textPrimaryDark = Color(0xFFFFFFFF);
  static const Color textSecondaryDark = Color(0xFFB3B3B3);
  static const Color textTertiaryDark = Color(0xFF808080);

  // Status colors
  static const Color success = Color(0xFF4CAF50);
  static const Color warning = Color(0xFFFF9800);
  static const Color error = Color(0xFFE53935);
  static const Color info = Color(0xFF2196F3);

  // Charging colors
  static const Color chargingAC = Color(0xFF4CAF50);  // Green for AC
  static const Color chargingDC = Color(0xFFFF9800);  // Orange for DC
}

/// App theme definitions
class AppThemes {
  /// Standard light theme (Material Design 3 with blue)
  static ThemeData get light => ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.blue,
      brightness: Brightness.light,
    ),
  );

  /// Standard dark theme (Material Design 3 with blue)
  static ThemeData get dark => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.blue,
      brightness: Brightness.dark,
    ),
  );

  /// XPENG-styled light theme
  static ThemeData get xpengLight => ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: const ColorScheme(
      brightness: Brightness.light,
      // Primary colors - XPENG blue
      primary: XPengColors.primary,
      onPrimary: Colors.white,
      primaryContainer: XPengColors.primaryLight20,
      onPrimaryContainer: XPengColors.primaryDark,
      // Secondary colors - XPENG green
      secondary: XPengColors.accentGreen,
      onSecondary: Colors.white,
      secondaryContainer: XPengColors.accentGreenLight20,
      onSecondaryContainer: XPengColors.accentGreenDark,
      // Tertiary
      tertiary: XPengColors.info,
      onTertiary: Colors.white,
      tertiaryContainer: XPengColors.info20,
      onTertiaryContainer: XPengColors.info,
      // Error
      error: XPengColors.error,
      onError: Colors.white,
      errorContainer: XPengColors.error20,
      onErrorContainer: XPengColors.error,
      // Surface & background - cream tones
      surface: XPengColors.surfaceLight,
      onSurface: XPengColors.textPrimaryLight,
      surfaceContainerHighest: XPengColors.backgroundLight,
      onSurfaceVariant: XPengColors.textSecondaryLight,
      // Outline
      outline: XPengColors.textTertiaryLight,
      outlineVariant: XPengColors.textTertiaryLight50,
      // Inverse
      inverseSurface: XPengColors.backgroundDark,
      onInverseSurface: XPengColors.textPrimaryDark,
      inversePrimary: XPengColors.primaryLight,
      // Shadow & scrim
      shadow: Colors.black26,
      scrim: Colors.black54,
    ),
    scaffoldBackgroundColor: XPengColors.backgroundLight,
    cardTheme: CardThemeData(
      color: XPengColors.cardLight,
      elevation: 2,
      shadowColor: Colors.black12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: XPengColors.backgroundLight,
      foregroundColor: XPengColors.textPrimaryLight,
      elevation: 0,
      centerTitle: false,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: XPengColors.primary,
        foregroundColor: Colors.white,
        elevation: 2,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: XPengColors.primary,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: XPengColors.primary,
        side: const BorderSide(color: XPengColors.primary),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: XPengColors.primary,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: XPengColors.backgroundLight,
      selectedColor: XPengColors.primary,
      labelStyle: const TextStyle(color: XPengColors.textPrimaryLight),
      secondaryLabelStyle: const TextStyle(color: Colors.white),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return XPengColors.primary;
        }
        return XPengColors.textTertiaryLight;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return XPengColors.primary50;
        }
        return XPengColors.textTertiaryLight30;
      }),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: XPengColors.primary,
      inactiveTrackColor: XPengColors.textTertiaryLight30,
      thumbColor: XPengColors.primary,
      overlayColor: XPengColors.primary20,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: XPengColors.primary,
      linearTrackColor: Color(0xFFE0E0E0),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: XPengColors.primary,
      foregroundColor: Colors.white,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: XPengColors.textSecondaryLight,
      textColor: XPengColors.textPrimaryLight,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: XPengColors.textTertiaryLight30,
      thickness: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: XPengColors.surfaceLight,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: XPengColors.textTertiaryLight30),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: XPengColors.textTertiaryLight30),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: XPengColors.primary, width: 2),
      ),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: XPengColors.surfaceLight,
      selectedItemColor: XPengColors.primary,
      unselectedItemColor: XPengColors.textTertiaryLight,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: XPengColors.surfaceLight,
      indicatorColor: XPengColors.primary20,
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return const IconThemeData(color: XPengColors.primary);
        }
        return const IconThemeData(color: XPengColors.textTertiaryLight);
      }),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: XPengColors.primary,
      unselectedLabelColor: XPengColors.textSecondaryLight,
      indicatorColor: XPengColors.primary,
      dividerColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: XPengColors.surfaceDark,
      contentTextStyle: const TextStyle(color: XPengColors.textPrimaryDark),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      behavior: SnackBarBehavior.floating,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: XPengColors.surfaceLight,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: XPengColors.surfaceLight,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
  );

  /// XPENG-styled dark theme (for potential future use)
  static ThemeData get xpengDark => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme(
      brightness: Brightness.dark,
      // Primary colors - XPENG blue
      primary: XPengColors.primary,
      onPrimary: Colors.white,
      primaryContainer: XPengColors.primaryDark30,
      onPrimaryContainer: XPengColors.primaryLight,
      // Secondary colors - XPENG green
      secondary: XPengColors.accentGreen,
      onSecondary: Colors.white,
      secondaryContainer: XPengColors.accentGreenDark30,
      onSecondaryContainer: XPengColors.accentGreenLight,
      // Tertiary
      tertiary: XPengColors.info,
      onTertiary: Colors.white,
      tertiaryContainer: XPengColors.info30,
      onTertiaryContainer: XPengColors.info,
      // Error
      error: XPengColors.error,
      onError: Colors.white,
      errorContainer: XPengColors.error30,
      onErrorContainer: XPengColors.error,
      // Surface & background - dark tones
      surface: XPengColors.surfaceDark,
      onSurface: XPengColors.textPrimaryDark,
      surfaceContainerHighest: XPengColors.backgroundDark,
      onSurfaceVariant: XPengColors.textSecondaryDark,
      // Outline
      outline: XPengColors.textTertiaryDark,
      outlineVariant: XPengColors.textTertiaryDark50,
      // Inverse
      inverseSurface: XPengColors.backgroundLight,
      onInverseSurface: XPengColors.textPrimaryLight,
      inversePrimary: XPengColors.primaryDark,
      // Shadow & scrim
      shadow: Colors.black54,
      scrim: Colors.black87,
    ),
    scaffoldBackgroundColor: XPengColors.backgroundDark,
    cardTheme: CardThemeData(
      color: XPengColors.cardDark,
      elevation: 4,
      shadowColor: Colors.black38,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: XPengColors.backgroundDark,
      foregroundColor: XPengColors.textPrimaryDark,
      elevation: 0,
      centerTitle: false,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: XPengColors.primary,
        foregroundColor: Colors.white,
        elevation: 2,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return XPengColors.primary;
        }
        return XPengColors.textTertiaryDark;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return XPengColors.primary50;
        }
        return XPengColors.textTertiaryDark30;
      }),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: XPengColors.primary,
      linearTrackColor: Color(0xFF404040),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: XPengColors.primary,
      foregroundColor: Colors.white,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: XPengColors.textSecondaryDark,
      textColor: XPengColors.textPrimaryDark,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: XPengColors.textTertiaryDark20,
      thickness: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: XPengColors.surfaceDark,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: XPengColors.textTertiaryDark30),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: XPengColors.textTertiaryDark30),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: XPengColors.primary, width: 2),
      ),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: XPengColors.surfaceDark,
      selectedItemColor: XPengColors.primary,
      unselectedItemColor: XPengColors.textTertiaryDark,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: XPengColors.cardDark,
      contentTextStyle: const TextStyle(color: XPengColors.textPrimaryDark),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      behavior: SnackBarBehavior.floating,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: XPengColors.surfaceDark,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: XPengColors.surfaceDark,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
  );

  /// Get ThemeData for a given AppThemeMode
  static ThemeData getTheme(AppThemeMode mode, Brightness systemBrightness) {
    switch (mode) {
      case AppThemeMode.light:
        return light;
      case AppThemeMode.dark:
        return dark;
      case AppThemeMode.system:
        return systemBrightness == Brightness.dark ? dark : light;
      case AppThemeMode.xpeng:
        return xpengLight;  // XPENG uses light theme by default
    }
  }

  /// Get ThemeMode for MaterialApp
  static ThemeMode getThemeMode(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
      case AppThemeMode.system:
        return ThemeMode.system;
      case AppThemeMode.xpeng:
        return ThemeMode.light;  // XPENG theme forces light mode
    }
  }
}
