import SwiftUI
import BootBarCore

/// Hardware options of an Android virtual device. Empty fields keep the system image default.
struct AvdOptionsForm: View {
    @Binding var options: AvdHardwareOptions
    var includesSdCard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            numberField("Memory (RAM)", unit: "MB", value: $options.ramMB, prompt: "2048")
            numberField("CPU cores", unit: nil, value: $options.cpuCores, prompt: "4")
            numberField("Internal storage", unit: "MB", value: $options.internalStorageMB, prompt: "6144")
            if includesSdCard {
                numberField("SD card", unit: "MB", value: $options.sdCardMB, prompt: "512")
            }
            numberField("VM heap", unit: "MB", value: $options.vmHeapMB, prompt: "256")
            numberField("Screen density", unit: "dpi", value: $options.lcdDensity, prompt: "420")
            Divider()
            choice("Graphics", selection: $options.gpuMode, values: AvdHardwareOptions.GPUMode.allCases, title: \.title)
            toggle("Device frame (bezel)", $options.showDeviceFrame)
            toggle("Hardware keyboard", $options.hardwareKeyboard)
            toggle("Always cold boot", $options.coldBootOnly)
            choice("Front camera", selection: $options.frontCamera, values: AvdHardwareOptions.Camera.allCases, title: \.title)
            choice("Back camera", selection: $options.backCamera, values: AvdHardwareOptions.Camera.allCases, title: \.title)
            choice("Orientation", selection: $options.initialOrientation,
                   values: AvdHardwareOptions.Orientation.allCases, title: \.rawValue.capitalized)
            Hint("Leave a field empty or on Default to keep the value from the system image.")
        }
    }

    private func numberField(_ title: String, unit: String?, value: Binding<Int?>, prompt: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).frame(width: 110, alignment: .leading)
            TextField("", text: Binding(
                get: { value.wrappedValue.map(String.init) ?? "" },
                set: { value.wrappedValue = Int($0.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil } }),
                      prompt: Text(prompt))
                .textFieldStyle(.roundedBorder).controlSize(.small).multilineTextAlignment(.trailing)
            if let unit { Text(unit).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 26, alignment: .leading) }
        }
    }

    private func toggle(_ title: String, _ value: Binding<Bool?>) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).frame(width: 110, alignment: .leading)
            Picker("", selection: value) {
                Text("Default").tag(Bool?.none)
                Text("Yes").tag(Bool?.some(true))
                Text("No").tag(Bool?.some(false))
            }
            .labelsHidden().pickerStyle(.segmented).controlSize(.small)
        }
    }

    private func choice<Value: Hashable>(_ title: String, selection: Binding<Value?>, values: [Value],
                                         title label: @escaping (Value) -> String) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).frame(width: 110, alignment: .leading)
            Picker("", selection: selection) {
                Text("Default").tag(Value?.none)
                ForEach(values, id: \.self) { Text(label($0)).tag(Value?.some($0)) }
            }
            .labelsHidden().controlSize(.small)
        }
    }
}
