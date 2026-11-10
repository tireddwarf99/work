/// Тема приложения по утверждённым макетам (светлая/тёмная).
library;

import 'package:flutter/material.dart';

/// Палитра макетов.
class AppColors {
  // Светлая тема.
  static const lightBackground = Color(0xFFFFFFFF);
  static const lightSidebar = Color(0xFFF0F3F8);
  static const lightCard = Color(0xFFFFFFFF);
  static const lightBorder = Color(0xFFE3E8EF);
  static const lightText = Color(0xFF17263B);
  static const lightMuted = Color(0xFF6B7A90);
  static const lightAccentBg = Color(0xFFE3F0FB);
  static const lightChipBg = Color(0xFFEAF3FB);

  // Тёмная тема.
  static const darkBackground = Color(0xFF0E1621);
  static const darkSidebar = Color(0xFF101A26);
  static const darkCard = Color(0xFF141F2B);
  static const darkBorder = Color(0xFF223145);
  static const darkText = Color(0xFFE8EEF6);
  static const darkMuted = Color(0xFF8FA1B8);
  static const darkAccentBg = Color(0xFF1B3247);
  static const darkChipBg = Color(0xFF1B3247);

  static const primary = Color(0xFF1B76D2);
  static const primaryDark = Color(0xFF7EB8FF);
  static const danger = Color(0xFFD24040);
  static const dueBlue = Color(0xFF1B76D2);
  static const dueBlueDark = Color(0xFF7EB8FF);
}

ThemeData buildLightTheme() {
  final base = ThemeData.light(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.lightBackground,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.primary,
      secondary: AppColors.primary,
      surface: AppColors.lightCard,
      error: AppColors.danger,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.lightText,
      displayColor: AppColors.lightText,
    ),
    dividerColor: AppColors.lightBorder,
    cardTheme: const CardThemeData(color: AppColors.lightCard),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.lightBackground,
      indicatorColor: AppColors.lightAccentBg,
    ),
    checkboxTheme: CheckboxThemeData(
      side: BorderSide(color: AppColors.lightMuted.withValues(alpha: 0.7)),
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? AppColors.primary : null,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.lightSidebar,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    ),
  );
}

ThemeData buildDarkTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.darkBackground,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.primaryDark,
      secondary: AppColors.primaryDark,
      surface: AppColors.darkCard,
      error: AppColors.danger,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.darkText,
      displayColor: AppColors.darkText,
    ),
    dividerColor: AppColors.darkBorder,
    cardTheme: const CardThemeData(color: AppColors.darkCard),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.darkBackground,
      indicatorColor: AppColors.darkAccentBg,
    ),
    checkboxTheme: CheckboxThemeData(
      side: BorderSide(color: AppColors.darkMuted.withValues(alpha: 0.7)),
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? AppColors.primaryDark : null,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.darkSidebar,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    ),
  );
}

/// Акцентный цвет срока в зависимости от темы.
Color dueAccent(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? AppColors.dueBlueDark
        : AppColors.dueBlue;

Color mutedText(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? AppColors.darkMuted
        : AppColors.lightMuted;

Color cardBorder(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? AppColors.darkBorder
        : AppColors.lightBorder;

Color sidebarBackground(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? AppColors.darkSidebar
        : AppColors.lightSidebar;

Color chipBackground(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? AppColors.darkChipBg
        : AppColors.lightChipBg;

Color accentBackground(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? AppColors.darkAccentBg
        : AppColors.lightAccentBg;

/// Приглушённый текст второстепенных подписей (макеты).
TextStyle? mutedStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodySmall?.copyWith(color: mutedText(context));
