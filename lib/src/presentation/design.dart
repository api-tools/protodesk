import 'package:flutter/material.dart';

/// Shared desktop roles: no widget chooses its own font metrics.
abstract final class DeskType {
  static const body = TextStyle(
    fontFamily: 'Satoshi',
    fontSize: 13,
    height: 18 / 13,
    fontWeight: FontWeight.w400,
  );
  static const label = TextStyle(
    fontFamily: 'Satoshi',
    fontSize: 13,
    height: 18 / 13,
    fontWeight: FontWeight.w500,
  );
  static const heading = TextStyle(
    fontFamily: 'Satoshi',
    fontSize: 13,
    height: 18 / 13,
    fontWeight: FontWeight.w700,
  );
  static const secondary = TextStyle(
    fontFamily: 'Satoshi',
    fontSize: 13,
    height: 18 / 13,
    fontWeight: FontWeight.w400,
  );
  static const title = TextStyle(
    fontFamily: 'Satoshi',
    fontSize: 13,
    height: 18 / 13,
    fontWeight: FontWeight.w700,
  );
  static const code = TextStyle(
    fontFamily: 'RobotoMono',
    fontSize: 12,
    height: 1.5,
    fontWeight: FontWeight.w400,
  );
}

abstract final class DeskSpace {
  static const small = 4.0,
      gap = 8.0,
      inset = 12.0,
      panel = 16.0,
      minimumPane = 240.0;
  static const control = 36.0,
      row = 36.0,
      header = 48.0,
      jsonRow = 20.0,
      indent = 16.0;
  static const fieldPadding = EdgeInsets.symmetric(
    horizontal: inset,
    vertical: 9,
  );
}

final deskTheme = ThemeData(
  useMaterial3: true,
  fontFamily: 'Satoshi',
  brightness: Brightness.dark,
  scaffoldBackgroundColor: const Color(0xff242e39),
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xff55d6b0),
    brightness: Brightness.dark,
    surface: const Color(0xff171e26),
  ),
  textTheme: const TextTheme(
    displayLarge: DeskType.title,
    displayMedium: DeskType.title,
    displaySmall: DeskType.title,
    headlineLarge: DeskType.title,
    headlineMedium: DeskType.title,
    headlineSmall: DeskType.title,
    titleLarge: DeskType.title,
    titleMedium: DeskType.heading,
    titleSmall: DeskType.heading,
    bodyLarge: DeskType.body,
    bodyMedium: DeskType.body,
    bodySmall: DeskType.secondary,
    labelLarge: DeskType.label,
    labelMedium: DeskType.label,
    labelSmall: DeskType.secondary,
  ),
  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
  inputDecorationTheme: InputDecorationThemeData(
    visualDensity: VisualDensity.standard,
    isDense: true,
    filled: true,
    fillColor: const Color(0xff111820),
    labelStyle: DeskType.label,
    floatingLabelStyle: DeskType.label,
    hintStyle: DeskType.body.copyWith(color: Colors.grey),
    helperStyle: DeskType.secondary,
    errorStyle: DeskType.secondary,
    errorMaxLines: 4,
    constraints: const BoxConstraints(minHeight: DeskSpace.control),
    prefixIconConstraints: const BoxConstraints(
      minWidth: DeskSpace.control,
      minHeight: DeskSpace.control,
    ),
    suffixIconConstraints: const BoxConstraints(
      minWidth: DeskSpace.control,
      minHeight: DeskSpace.control,
    ),
    border: OutlineInputBorder(
      gapPadding: 0,
      borderRadius: BorderRadius.circular(4),
      borderSide: const BorderSide(color: Color(0xff344048)),
    ),
    contentPadding: DeskSpace.fieldPadding,
  ),
  filledButtonTheme: FilledButtonThemeData(style: _buttonStyle),
  textButtonTheme: TextButtonThemeData(style: _buttonStyle),
  outlinedButtonTheme: OutlinedButtonThemeData(style: _buttonStyle),
  iconButtonTheme: IconButtonThemeData(
    style: ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size.square(DeskSpace.control)),
      maximumSize: const WidgetStatePropertyAll(Size.square(DeskSpace.control)),
      padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
      iconSize: const WidgetStatePropertyAll(16),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  ),
  listTileTheme: const ListTileThemeData(
    titleTextStyle: DeskType.label,
    subtitleTextStyle: DeskType.secondary,
    minVerticalPadding: 4,
    contentPadding: EdgeInsets.symmetric(horizontal: DeskSpace.inset),
  ),
  dialogTheme: const DialogThemeData(
    titleTextStyle: DeskType.title,
    contentTextStyle: DeskType.body,
    backgroundColor: Color(0xff171e26),
  ),
  expansionTileTheme: const ExpansionTileThemeData(
    backgroundColor: Colors.transparent,
    collapsedBackgroundColor: Colors.transparent,
    tilePadding: EdgeInsets.zero,
    childrenPadding: EdgeInsets.zero,
    shape: Border(),
    collapsedShape: Border(),
  ),
  tooltipTheme: TooltipThemeData(
    textStyle: DeskType.secondary.copyWith(color: const Color(0xff111820)),
  ),
  checkboxTheme: const CheckboxThemeData(
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
  ),
);

final _buttonStyle = ButtonStyle(
  textStyle: const WidgetStatePropertyAll(DeskType.label),
  minimumSize: const WidgetStatePropertyAll(Size(0, DeskSpace.control)),
  fixedSize: const WidgetStatePropertyAll(Size.fromHeight(DeskSpace.control)),
  visualDensity: VisualDensity.standard,
  padding: const WidgetStatePropertyAll(
    EdgeInsets.symmetric(horizontal: DeskSpace.inset),
  ),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
  ),
);

/// Material dropdowns reserve 24 px internally even when their text is 18 px.
/// Bound the full hit target to the control height and pad its content inside.
/// Focus remains on DropdownButton, including keyboard menu navigation.
class DeskDropdown<T> extends StatefulWidget {
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final InputDecoration decoration;
  const DeskDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.decoration = const InputDecoration(),
  });
  @override
  State<DeskDropdown<T>> createState() => _DeskDropdownState<T>();
}

class _DeskDropdownState<T> extends State<DeskDropdown<T>> {
  bool focused = false, hovering = false;
  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onFocusChange: (value) => setState(() => focused = value),
    child: MouseRegion(
      onEnter: (_) => setState(() => hovering = true),
      onExit: (_) => setState(() => hovering = false),
      child: InputDecorator(
        decoration: widget.decoration.copyWith(
          enabled: widget.onChanged != null,
          // Padding lives inside the dropdown's InkWell so the whole border
          // remains clickable. Effective content padding matches TextField.
          contentPadding: EdgeInsets.zero,
          hintText: '',
        ),
        isFocused: focused,
        isHovering: hovering,
        isEmpty: widget.value == null,
        child: SizedBox(
          height: DeskSpace.control,
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: widget.value,
              padding: DeskSpace.fieldPadding,
              hint: Text(widget.decoration.hintText ?? ''),
              isExpanded: true,
              isDense: true,
              iconSize: 18,
              style: DeskType.body,
              items: widget.items,
              onChanged: widget.onChanged,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Two equal-width mode buttons share the exact metrics of Invoke and Connect.
/// SegmentedButton hard-codes a 40 px minimum independently of ButtonStyle.
class DeskModeSwitch extends StatelessWidget {
  final bool json;
  final ValueChanged<bool> onChanged;
  const DeskModeSwitch({
    super.key,
    required this.json,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    var labelWidth = 0.0;
    for (final label in ['Form', 'JSON']) {
      final text = TextPainter(
        text: TextSpan(text: label, style: DeskType.label),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      if (text.width > labelWidth) labelWidth = text.width;
      text.dispose();
    }
    final contentWidth = labelWidth + 16 + DeskSpace.gap;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final mode in [false, true])
          Semantics(
            selected: json == mode,
            child: json == mode
                ? FilledButton(
                    onPressed: () => onChanged(mode),
                    child: _label(mode, contentWidth),
                  )
                : OutlinedButton(
                    onPressed: () => onChanged(mode),
                    child: _label(mode, contentWidth),
                  ),
          ),
      ],
    );
  }

  Widget _label(bool mode, double width) => SizedBox(
    width: width,
    child: Row(
      children: [
        Icon(mode ? Icons.code : Icons.list_alt, size: 16),
        const SizedBox(width: DeskSpace.gap),
        Text(mode ? 'JSON' : 'Form'),
      ],
    ),
  );
}
