import SwiftUI
import Defaults
import Settings

/// Storage settings: which content types to save, history size, max item size, and sort order.
struct StorageSettingsPane: View {
  /// Syncs the save-files/images/text toggles with `enabledPasteboardTypes`.
  @Observable
  class ViewModel {
    private(set) var storageSize: String
    private let readStorageSize: @MainActor () -> String

    /// Adds or removes the file UTIs from `enabledPasteboardTypes` when toggled.
    var saveFiles = false {
      didSet {
        Defaults.withoutPropagation {
          if saveFiles {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.files.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.files.types)
          }
        }
      }
    }

    /// Adds or removes the image UTIs from `enabledPasteboardTypes` when toggled.
    var saveImages = false {
      didSet {
        Defaults.withoutPropagation {
          if saveImages {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.images.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.images.types)
          }
        }
      }
    }

    /// Adds or removes the text UTIs from `enabledPasteboardTypes` when toggled.
    var saveText = false {
      didSet {
        Defaults.withoutPropagation {
          if saveText {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.text.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.text.types)
          }
        }
      }
    }

    private var observer: Defaults.Observation?

    /// Observes `enabledPasteboardTypes` and reflects the file/image/text subsets.
    @MainActor
    init(readStorageSize: @escaping @MainActor () -> String) {
      self.readStorageSize = readStorageSize
      storageSize = readStorageSize()
      observer = Defaults.observe(.enabledPasteboardTypes) { change in
        self.saveFiles = change.newValue.isSuperset(of: StorageType.files.types)
        self.saveImages = !change.newValue.isDisjoint(with: StorageType.images.types)
        self.saveText = change.newValue.isSuperset(of: StorageType.text.types)
      }
    }

    /// Refreshes the displayed on-disk size from the composition-owned reader.
    @MainActor
    func refreshStorageSize() {
      storageSize = readStorageSize()
    }

    deinit {
      observer?.invalidate()
    }
  }

  @Default(.size) private var size
  @Default(.maxClipboardContentSize) private var maxClipboardContentSize
  @Default(.sortBy) private var sortBy

  @State private var viewModel: ViewModel

  /// Creates the pane with the composition-owned reader for the current
  /// on-disk storage size.
  @MainActor
  init(readStorageSize: @escaping @MainActor () -> String) {
    _viewModel = State(initialValue: ViewModel(readStorageSize: readStorageSize))
  }

  private let sizeFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 1
    formatter.maximum = 999
    return formatter
  }()

  private let maxClipboardContentSizeFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = NSNumber(value: ClipboardContentSizeLimit.minMegabytes)
    formatter.maximum = NSNumber(value: ClipboardContentSizeLimit.maxMegabytes)
    return formatter
  }()

  var body: some View {
    Settings.Container(contentWidth: 450) {
      Settings.Section(
        bottomDivider: true,
        label: { Text("Save", tableName: "StorageSettings") }
      ) {
        Toggle(
          isOn: $viewModel.saveFiles,
          label: { Text("Files", tableName: "StorageSettings") }
        )
        Toggle(
          isOn: $viewModel.saveImages,
          label: { Text("Images", tableName: "StorageSettings") }
        )
        Toggle(
          isOn: $viewModel.saveText,
          label: { Text("Text", tableName: "StorageSettings") }
        )
        Text("SaveDescription", tableName: "StorageSettings")
          .controlSize(.small)
          .foregroundStyle(.gray)
      }

      Settings.Section(label: { Text("Size", tableName: "StorageSettings") }) {
        HStack {
          TextField("", value: $size, formatter: sizeFormatter)
            .frame(width: 80)
            .help(Text("SizeTooltip", tableName: "StorageSettings"))
          Stepper("", value: $size, in: 1...999)
            .labelsHidden()
          Text(viewModel.storageSize)
            .controlSize(.small)
            .foregroundStyle(.gray)
            .help(Text("CurrentSizeTooltip", tableName: "StorageSettings"))
            .onAppear {
              viewModel.refreshStorageSize()
            }
        }
      }

      Settings.Section(label: { Text("MaxClipboardContentSize", tableName: "StorageSettings") }) {
        HStack {
          TextField("", value: $maxClipboardContentSize, formatter: maxClipboardContentSizeFormatter)
            .frame(width: 80)
            .help(Text("MaxClipboardContentSizeTooltip", tableName: "StorageSettings"))
          Stepper(
            "",
            value: $maxClipboardContentSize,
            in: ClipboardContentSizeLimit.minMegabytes...ClipboardContentSizeLimit.maxMegabytes
          )
            .labelsHidden()
          Text("MaxClipboardContentSizeUnit", tableName: "StorageSettings")
            .controlSize(.small)
            .foregroundStyle(.gray)
        }
      }

      Settings.Section(label: { Text("SortBy", tableName: "StorageSettings") }) {
        Picker("", selection: $sortBy) {
          ForEach(Sorter.By.allCases) { mode in
            Text(mode.description)
          }
        }
        .labelsHidden()
        .frame(width: 160, alignment: .leading)
        .help(Text("SortByTooltip", tableName: "StorageSettings"))
      }
    }
  }
}

#Preview {
  StorageSettingsPane(readStorageSize: { "0 B" })
    .environment(\.locale, .init(identifier: "en"))
}
