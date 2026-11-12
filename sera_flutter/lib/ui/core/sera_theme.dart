import 'package:flutter/material.dart';

abstract final class SeraColors {
  static const bg = Color(0xFFF7F8FA),
      surface = Colors.white,
      ink = Color(0xFF182321),
      muted = Color(0xFF65736D),
      mutedOnMint = Color(0xFF56655F),
      line = Color(0xFFE2E7E5),
      control = Color(0xFF7C8A83),
      brand = Color(0xFF176B59),
      brandStrong = Color(0xFF105443),
      mint = Color(0xFFE7F2EC),
      amber = Color(0xFF946018),
      amberBg = Color(0xFFFCF3DF),
      red = Color(0xFFB5473E),
      redBg = Color(0xFFFBECE9),
      blue = Color(0xFF41677C);
}

ThemeData seraTheme() => ThemeData(
  useMaterial3: true,
  visualDensity: VisualDensity.standard,
  materialTapTargetSize: MaterialTapTargetSize.padded,
  fontFamily: 'SeraSans',
  scaffoldBackgroundColor: SeraColors.bg,
  colorScheme: ColorScheme.fromSeed(seedColor: SeraColors.brand).copyWith(
    primary: SeraColors.brand,
    surface: Colors.white,
    onSurface: SeraColors.ink,
    error: SeraColors.red,
  ),
  textTheme: const TextTheme(
    bodyMedium: TextStyle(fontSize: 15, height: 22 / 15, color: SeraColors.ink),
    bodyLarge: TextStyle(fontSize: 15, height: 22 / 15, color: SeraColors.ink),
    bodySmall: TextStyle(
      fontSize: 13,
      height: 20 / 13,
      color: SeraColors.muted,
    ),
    titleLarge: TextStyle(
      fontSize: 18,
      height: 26 / 18,
      fontWeight: FontWeight.w600,
      color: SeraColors.ink,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      height: 1.5,
      fontWeight: FontWeight.w500,
    ),
    labelLarge: TextStyle(
      fontSize: 15,
      height: 22 / 15,
      fontWeight: FontWeight.w600,
    ),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: SeraColors.bg,
    foregroundColor: SeraColors.ink,
    elevation: 0,
    scrolledUnderElevation: 0,
    centerTitle: true,
  ),
  dividerTheme: const DividerThemeData(
    color: SeraColors.line,
    thickness: 1,
    space: 24,
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(
      minimumSize: const Size(48, 48),
      textStyle: const TextStyle(
        fontFamily: 'SeraSans',
        fontSize: 13,
        height: 20 / 13,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  ),
  checkboxTheme: CheckboxThemeData(
    side: const BorderSide(color: SeraColors.control, width: 1.5),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
  ),
  chipTheme: ChipThemeData(
    backgroundColor: SeraColors.surface,
    selectedColor: SeraColors.mint,
    side: const BorderSide(color: SeraColors.control),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    labelStyle: const TextStyle(
      fontFamily: 'SeraSans',
      fontSize: 13,
      height: 20 / 13,
    ),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  ),
  bottomSheetTheme: const BottomSheetThemeData(
    backgroundColor: SeraColors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
    errorMaxLines: 4,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: SeraColors.line),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: SeraColors.line),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: SeraColors.brand, width: 1.5),
    ),
  ),
  snackBarTheme: SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    backgroundColor: SeraColors.ink,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  ),
);
