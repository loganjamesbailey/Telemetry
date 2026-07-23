import SwiftUI
import TelemetryShared

/// Preset list + editor + inspector. Edits apply live when the edited preset
/// is the one currently driving the fan.
struct CurvesTab: View {
    @Environment(SensorStore.self) private var sensors
    @Environment(FanControlStore.self) private var control
    @Environment(PresetStore.self) private var presets

    @State private var editingID: UUID?
    @State private var draft: FanCurve?

    private var minRPM: Double { sensors.fan?.minRPM ?? 1199 }
    private var maxRPM: Double { sensors.fan?.maxRPM ?? 7199 }

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.space16) {
            presetList
                .frame(width: 180)
            editorColumn
        }
        .onAppear { selectInitial() }
    }

    // MARK: - Preset list

    private var presetList: some View {
        VStack(alignment: .leading, spacing: Metrics.space8) {
            FieldLabel(text: "Presets")
            ForEach(presets.presets) { preset in
                presetRow(preset)
            }
            Button("New preset") {
                let created = presets.add(basedOn: presets.activePreset)
                select(created)
            }
            .buttonStyle(.plain)
            .font(Typo.caption)
            .foregroundStyle(Palette.accentData)
            .padding(.top, Metrics.space4)
        }
    }

    private func presetRow(_ preset: FanCurve) -> some View {
        let isEditing = preset.id == editingID
        let isActive = preset.id == presets.activePresetID
        return HStack(spacing: Metrics.space8) {
            Circle()
                .fill(isActive ? Palette.accentControl : Palette.hairline)
                .frame(width: 5, height: 5)
            Text(preset.name)
                .font(Typo.body)
                .foregroundStyle(isEditing ? Palette.textPrimary : Palette.textSecondary)
            Spacer()
        }
        .padding(.vertical, Metrics.space4)
        .padding(.horizontal, Metrics.space8)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusControl)
                .fill(isEditing ? Palette.bgOverlay : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { select(preset) }
    }

    // MARK: - Editor

    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: Metrics.space16) {
            if draft != nil {
                Card {
                    CurveEditorView(
                        curve: Binding(
                            get: { draft ?? PresetStore.defaultPresets[0] },
                            set: { draft = $0 }
                        ),
                        minRPM: minRPM,
                        maxRPM: maxRPM,
                        liveTempC: draft.flatMap { sensors.snapshot.reading($0.input)?.celsius },
                        onCommit: commit
                    )
                    .frame(minHeight: 300)
                }
                inspector
            } else {
                Text("Select a preset")
                    .font(Typo.body)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private var inspector: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.space12) {
                if let binding = draftBinding() {
                    HStack(spacing: Metrics.space16) {
                        VStack(alignment: .leading, spacing: Metrics.space4) {
                            FieldLabel(text: "Name")
                            TextField("Name", text: binding.name, onCommit: commit)
                                .textFieldStyle(.plain)
                                .font(Typo.body)
                                .frame(width: 140)
                        }
                        VStack(alignment: .leading, spacing: Metrics.space4) {
                            FieldLabel(text: "Input sensor")
                            sensorPicker(binding)
                        }
                        Spacer()
                        activateButton
                    }

                    Hairline()

                    HStack(spacing: Metrics.space24) {
                        labeledStepper(
                            "Hysteresis", value: binding.hysteresisC,
                            range: 0...10, step: 1, unit: "°C"
                        )
                        labeledStepper(
                            "Spin-down dwell", value: binding.minDwellSeconds,
                            range: 0...60, step: 2, unit: "s"
                        )
                        hybridControls(binding)
                        Spacer()
                    }
                }
            }
        }
    }

    private var activateButton: some View {
        let isDriving = isDraftDriving
        return Button(isDriving ? "Driving fan" : "Use this curve") {
            guard let draft else { return }
            presets.activePresetID = draft.id
            control.apply(.curve(draft), maxRPM: maxRPM)
        }
        .buttonStyle(.plain)
        .font(Typo.body)
        .foregroundStyle(isDriving ? Palette.nominal : Palette.accentData)
        .disabled(!control.isReady)
    }

    private var isDraftDriving: Bool {
        if case .curve(let active) = control.mode, active.id == draft?.id { return true }
        return false
    }

    private func sensorPicker(_ binding: Binding<FanCurve>) -> some View {
        Picker("", selection: binding.input) {
            Section("Derived") {
                ForEach(sensors.virtualReadings) { reading in
                    Text(reading.name).tag(reading.id)
                }
            }
            Section("Sensors") {
                ForEach(sensors.physicalReadings.prefix(24)) { reading in
                    Text(reading.name).tag(reading.id)
                }
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 200)
        .onChange(of: binding.wrappedValue.input) { commit() }
    }

    private func labeledStepper(
        _ label: String, value: Binding<Double>,
        range: ClosedRange<Double>, step: Double, unit: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space4) {
            FieldLabel(text: label)
            HStack(spacing: Metrics.space4) {
                Stepper(
                    value: value, in: range, step: step,
                    onEditingChanged: { editing in if !editing { commit() } }
                ) {
                    Text(verbatim: "\(Int(value.wrappedValue)) \(unit)")
                        .font(Typo.readoutSmall)
                }
                .controlSize(.small)
            }
        }
    }

    private func hybridControls(_ binding: Binding<FanCurve>) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space4) {
            FieldLabel(text: "Zero-RPM auto zone")
            HStack(spacing: Metrics.space8) {
                Toggle("", isOn: Binding(
                    get: { binding.wrappedValue.hybridAuto != nil },
                    set: { on in
                        binding.wrappedValue.hybridAuto = on
                            ? HybridAutoConfig(releaseBelowC: 55, reacquireAboveC: 63)
                            : nil
                        commit()
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()

                if let hybrid = binding.wrappedValue.hybridAuto {
                    Stepper(
                        value: Binding(
                            get: { hybrid.releaseBelowC },
                            set: { newValue in
                                var h = hybrid
                                h.releaseBelowC = newValue
                                h.reacquireAboveC = max(h.reacquireAboveC, newValue + 2)
                                binding.wrappedValue.hybridAuto = h
                            }
                        ),
                        in: 30...90, step: 1,
                        onEditingChanged: { editing in if !editing { commit() } }
                    ) {
                        Text(verbatim: "below \(Int(hybrid.releaseBelowC))° → macOS")
                            .font(Typo.readoutSmall)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Selection & persistence

    private func selectInitial() {
        if draft == nil, let first = presets.activePreset ?? presets.presets.first {
            select(first)
        }
    }

    private func select(_ preset: FanCurve) {
        editingID = preset.id
        draft = preset
    }

    private func draftBinding() -> Binding<FanCurve>? {
        guard draft != nil else { return nil }
        return Binding(
            get: { draft ?? PresetStore.defaultPresets[0] },
            set: { draft = $0 }
        )
    }

    /// Persist the draft; if this preset is currently driving the fan, apply
    /// the edit live so the editor is honest about what the fan will do.
    private func commit() {
        guard var updated = draft else { return }
        updated = updated.sanitized(minRPM: minRPM, maxRPM: maxRPM)
        draft = updated
        presets.update(updated)
        if isDraftDriving {
            control.apply(.curve(updated), maxRPM: maxRPM)
        }
    }
}
