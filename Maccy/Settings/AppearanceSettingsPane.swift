import AppKit
import SwiftUI
import Defaults
import enum Settings.Settings

/// UI metadata for a numeric `Defaults` preference stepper: the valid range, the
/// unit shown beside the field, and the localized label/tooltip keys. Co-locates
/// what each numeric control previously re-declared separately in a
/// `NumberFormatter`, a `Stepper`, and a tooltip string, removing the drift.
struct NumericPreferenceOption {
  let range: ClosedRange<Int>
  let unit: String
  let labelKey: String
  let tooltipKey: String
  let tableName: String
  let formatter: NumberFormatter

  init(
    range: ClosedRange<Int>,
    unit: String,
    labelKey: String,
    tooltipKey: String,
    tableName: String
  ) {
    self.range = range
    self.unit = unit
    self.labelKey = labelKey
    self.tooltipKey = tooltipKey
    self.tableName = tableName
    let formatter = NumberFormatter()
    formatter.minimum = NSNumber(value: range.lowerBound)
    formatter.maximum = NSNumber(value: range.upperBound)
    self.formatter = formatter
  }

  static let imageMaxHeight = NumericPreferenceOption(
    range: 1...200, unit: "px",
    labelKey: "ImageHeight", tooltipKey: "ImageHeightTooltip",
    tableName: "AppearanceSettings"
  )
  static let textRowLines = NumericPreferenceOption(
    range: 1...4, unit: "lines",
    labelKey: "TextRowLines", tooltipKey: "TextRowLinesTooltip",
    tableName: "AppearanceSettings"
  )
  static let imageMaxPreviewPixels = NumericPreferenceOption(
    range: 0...4000, unit: "px",
    labelKey: "ImageMaxPreviewPixels", tooltipKey: "ImageMaxPreviewPixelsTooltip",
    tableName: "AppearanceSettings"
  )
  static let textPreviewLimit = NumericPreferenceOption(
    range: 0...100_000, unit: "chars",
    labelKey: "TextPreviewLimit", tooltipKey: "TextPreviewLimitTooltip",
    tableName: "AppearanceSettings"
  )
  static let previewDelay = NumericPreferenceOption(
    range: 0...100_000, unit: "ms",
    labelKey: "PreviewDelay", tooltipKey: "PreviewDelayTooltip",
    tableName: "AppearanceSettings"
  )
  static let previewMinimumHeightPercent = NumericPreferenceOption(
    range: 25...100, unit: "%",
    labelKey: "PreviewMinimumHeightPercent", tooltipKey: "PreviewMinimumHeightPercentTooltip",
    tableName: "AppearanceSettings"
  )
}

/// A labeled numeric preference field rendered from a `NumericPreferenceOption`:
/// a `Settings.Section` with a text field bound to a `Defaults` integer, the
/// unit shown beside it, and a stepper over the option's range — so the range,
/// formatter, unit, label, and tooltip are declared once.
@MainActor
private func labeledNumericPreference(
  value: Binding<Int>,
  option: NumericPreferenceOption
) -> Settings.Section {
  Settings.Section(label: { Text(LocalizedStringKey(option.labelKey), tableName: option.tableName) }) {
    HStack {
      TextField("", value: value, formatter: option.formatter)
        .frame(width: 120)
        .help(Text(LocalizedStringKey(option.tooltipKey), tableName: option.tableName))
      Text(verbatim: option.unit)
        .foregroundStyle(.secondary)
        .fixedSize()
      Stepper("", value: value, in: option.range)
        .labelsHidden()
    }
  }
}

/// Appearance settings: popup position, sizes, preview limits, menu icon, and visibility toggles.
struct AppearanceSettingsPane: View {
  @Default(.popupPosition) private var popupAt
  @Default(.popupScreen) private var popupScreen
  @Default(.pinTo) private var pinTo
  @Default(.imageMaxHeight) private var imageHeight
  @Default(.textRowLines) private var textRowLines
  @Default(.imageMaxPreviewPixels) private var imageMaxPreviewPixels
  @Default(.previewDelay) private var previewDelay
  @Default(.previewMinimumHeightPercent) private var previewMinimumHeightPercent
  @Default(.textPreviewLimit) private var textPreviewLimit
  @Default(.highlightMatch) private var highlightMatch
  @Default(.menuIcon) private var menuIcon
  @Default(.showInStatusBar) private var showInStatusBar
  @Default(.showSearch) private var showSearch
  @Default(.searchVisibility) private var searchVisibility
  @Default(.showFooter) private var showFooter
  @Default(.windowPosition) private var windowPosition
  @Default(.showApplicationIcons) private var showApplicationIcons

  @State private var screens = NSScreen.screens

  var body: some View {
    Settings.Container(contentWidth: 650) {
      Settings.Section(label: { Text("PopupAt", tableName: "AppearanceSettings") }) {
        HStack {
          Picker("", selection: $popupAt) {
            ForEach(PopupPosition.allCases) { position in
              if position == .center || position == .lastPosition, screens.count > 1 {
                screenPicker(for: position)
              } else {
                Text(position.description)
              }
            }
          }
          .labelsHidden()
          .frame(width: 141, alignment: .leading)
          .help(Text("PopupAtTooltip", tableName: "AppearanceSettings"))

          if popupAt == .lastPosition {
            Button {
              _windowPosition.reset()
            } label: {
              Image(systemName: "arrow.uturn.backward.circle.fill")
                .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .help(Text("PopupAtLastLocationReset", tableName: "AppearanceSettings"))
            .disabled(windowPosition == _windowPosition.defaultValue)
          }
        }
      }

      Settings.Section(label: { Text("PinTo", tableName: "AppearanceSettings") }) {
        Picker("", selection: $pinTo) {
          ForEach(PinsPosition.allCases) { position in
            Text(position.description)
          }
        }
        .labelsHidden()
        .frame(width: 141, alignment: .leading)
        .help(Text("PinToTooltip", tableName: "AppearanceSettings"))
      }

      labeledNumericPreference(value: $imageHeight, option: .imageMaxHeight)

      labeledNumericPreference(value: $textRowLines, option: .textRowLines)

      labeledNumericPreference(value: $imageMaxPreviewPixels, option: .imageMaxPreviewPixels)

      labeledNumericPreference(value: $textPreviewLimit, option: .textPreviewLimit)

      labeledNumericPreference(value: $previewDelay, option: .previewDelay)

      labeledNumericPreference(
        value: $previewMinimumHeightPercent,
        option: .previewMinimumHeightPercent
      )

      Settings.Section(
        bottomDivider: true,
        label: { Text("HighlightMatches", tableName: "AppearanceSettings") }
      ) {
        Picker("", selection: $highlightMatch) {
          ForEach(HighlightMatch.allCases) { match in
            Text(match.description)
          }
        }
        .labelsHidden()
        .frame(width: 141, alignment: .leading)
        .help(Text("HighlightMatchesTooltip", tableName: "AppearanceSettings"))
      }

      Settings.Section(title: "") {
        Defaults.Toggle(key: .showSpecialSymbols) {
          Text("ShowSpecialSymbols", tableName: "AppearanceSettings")
        }
        .help(Text("ShowSpecialSymbolsTooltip", tableName: "AppearanceSettings"))

        HStack {
          Defaults.Toggle(key: .showInStatusBar) {
            Text("ShowMenuIcon", tableName: "AppearanceSettings")
          }

          Picker("", selection: $menuIcon) {
            ForEach(MenuIcon.allCases) { icon in
              Image(nsImage: icon.image)
            }
          }
          .labelsHidden()
          .scaledToFit()
          .disabled(!showInStatusBar)
          .controlSize(.small)
        }

        Defaults.Toggle(key: .showRecentCopyInMenuBar) {
          Text("ShowRecentCopyInMenuBar", tableName: "AppearanceSettings")
        }
        HStack {
          Defaults.Toggle(key: .showSearch) {
            Text("ShowSearchField", tableName: "AppearanceSettings")
          }

          Picker("", selection: $searchVisibility) {
            ForEach(SearchVisibility.allCases) { type in
              Text(type.description)
            }
          }
          .labelsHidden()
          .scaledToFit()
          .disabled(!showSearch)
          .controlSize(.small)
        }
        Defaults.Toggle(key: .showTitle) {
          Text("ShowTitleBeforeSearchField", tableName: "AppearanceSettings")
        }
        Defaults.Toggle(key: .showApplicationIcons) {
          Text("ShowApplicationIcons", tableName: "AppearanceSettings")
        }

        Defaults.Toggle(key: .showFooter) {
          Text("ShowFooter", tableName: "AppearanceSettings")
        }
        Text("OpenPreferencesWarning", tableName: "AppearanceSettings")
          .opacity(showFooter ? 0 : 1)
          .controlSize(.small)
          .foregroundStyle(.gray)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
      screens = NSScreen.screens
    }
  }

  /// Picker for choosing which screen a center/last-position popup opens on.
  @ViewBuilder
  private func screenPicker(for position: PopupPosition) -> some View {
    let screenBinding: Binding<Int> = Binding {
      return popupScreen
    } set: {
      popupScreen = $0
      popupAt = position
    }

    Picker(selection: screenBinding) {
      Text(labelForScreen(index: 0))
        .tag(0)

      ForEach(screens.indices, id: \.self) { index in
        Text(labelForScreen(index: index + 1))
          .tag(index + 1)
      }
    } label: {
      if popupAt == position {
        Text("\(position.description) (\(labelForScreen(index: popupScreen)))")
      } else {
        Text(position.description)
      }
    }
  }

  /// Returns the display name for a screen index (0 = active screen).
  private func labelForScreen(index screenIndex: Int) -> String {
    switch screenIndex {
    case 0:
      return String(localized: "ActiveScreen", table: "AppearanceSettings")
    case _:
      return screens[screenIndex - 1].localizedName
    }
  }
}

#Preview {
  AppearanceSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
