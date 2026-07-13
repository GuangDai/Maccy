import SwiftUI
import Defaults

/// Owns the value rule for replacing one configured ignore regexp.
enum IgnoreRegexpEditor {
  static func replacing(
    _ original: String,
    with draft: String,
    in patterns: [String]
  ) -> [String] {
    guard !draft.isEmpty,
          draft != original,
          let index = patterns.firstIndex(of: original) else {
      return patterns
    }
    var result = patterns
    result[index] = draft
    return result
  }
}

/// Tab for managing regular expressions whose matching copies are ignored.
struct IgnoreRegexpsSettingsView: View {
  @Default(.ignoreRegexp) private var ignoredRegexps

  @FocusState private var focus: String.ID?
  @State private var selection = ""

  var body: some View {
    VStack(alignment: .leading) {
      List(selection: $selection) {
        ForEach(ignoredRegexps) { regexp in
          IgnoreRegexpRow(regexp: regexp, focus: $focus) { draft in
            ignoredRegexps = IgnoreRegexpEditor.replacing(
              regexp,
              with: draft,
              in: ignoredRegexps
            )
          }
        }
      }.onDeleteCommand {
        remove(selection)
      }

      ControlGroup {
        Button("", systemImage: "plus") {
          ignoredRegexps.append("^[a-zA-Z0-9]{50}$")
          focus = "^[a-zA-Z0-9]{50}$"
        }
        Button("", systemImage: "minus") {
          remove(selection)
        }
      }.frame(width: 50)

      Text("IgnoredRegexpsDescription", tableName: "IgnoreSettings")
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .controlSize(.small)
    }.padding()
  }

  /// Removes the given regular expression from the ignored list.
  private func remove(_ regexp: String?) {
    guard let regexp else { return }

    ignoredRegexps.removeAll(where: { $0 == regexp })
  }
}

private struct IgnoreRegexpRow: View {
  let regexp: String
  @FocusState.Binding var focus: String.ID?
  let onSubmit: (String) -> Void
  @State private var draft: String

  init(
    regexp: String,
    focus: FocusState<String.ID?>.Binding,
    onSubmit: @escaping (String) -> Void
  ) {
    self.regexp = regexp
    _focus = focus
    self.onSubmit = onSubmit
    _draft = State(initialValue: regexp)
  }

  var body: some View {
    TextField("", text: $draft)
      .onSubmit { onSubmit(draft) }
      .focused($focus, equals: regexp)
  }
}

#Preview {
  IgnoreRegexpsSettingsView()
    .environment(\.locale, .init(identifier: "en"))
}
