import SwiftUI

/// Easy FSI / FAR calculator: Maharashtra UDCPR-2020 tables, or a ratio from anywhere in the world.
struct BuildFSIView: View {
    var plotPreset: String = ""
    @AppStorage("fsi.mode") private var mode = "udcpr"
    @AppStorage("fsi.sqft") private var inSqft = false
    @AppStorage("fsi.authority") private var authorityRaw = FSIRules.Authority.corporation.rawValue
    @AppStorage("fsi.area") private var areaRaw = FSIRules.Area.nonCongested.rawValue
    @State private var residential = true
    @State private var plot = ""
    @State private var deductions = ""
    @State private var road = 12.0
    @State private var asr = ""
    @State private var usePremium = true
    @State private var useTDR = true
    @State private var useAncillary = true
    // World
    @AppStorage("fsi.region") private var region = "in"
    @State private var ratio = ""
    @State private var bonus = ""
    @State private var coverage = ""

    private var authority: FSIRules.Authority { FSIRules.Authority(rawValue: authorityRaw) ?? .corporation }
    private var area: FSIRules.Area { FSIRules.Area(rawValue: areaRaw) ?? .nonCongested }
    private var toSqm: Double { inSqft ? 1 / FSIRules.sqftPerSqm : 1 }
    private var unit: String { inSqft ? "sq ft" : "m²" }

    private var result: FSIRules.Result {
        FSIRules.udcpr(gross: BuildData.number(plot) * toSqm, deductions: BuildData.number(deductions) * toSqm, road: road,
                       authority: authority, area: area, residential: residential, asrRate: BuildData.number(asr),
                       usePremium: usePremium, useTDR: useTDR, useAncillary: useAncillary)
    }

    var body: some View {
        Form {
            Section {
                Picker("Rules", selection: $mode) {
                    Text("Maharashtra UDCPR").tag("udcpr")
                    Text("Any country").tag("world")
                }
                .pickerStyle(.segmented)
                Picker("Area unit", selection: $inSqft) {
                    Text("Square metres").tag(false)
                    Text("Square feet").tag(true)
                }
                .pickerStyle(.segmented)
            }
            if mode == "udcpr" { udcprInputs; udcprResult } else { worldInputs }
        }
        .navigationTitle("FSI calculator")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if plot.isEmpty { plot = plotPreset } }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: UDCPR

    @ViewBuilder private var udcprInputs: some View {
        Section {
            TextField("Plot area (\(unit))", text: $plot).keyboardType(.decimalPad).font(.title3.weight(.semibold))
            TextField("Less road widening / reservation / amenity (\(unit))", text: $deductions).keyboardType(.decimalPad)
        } header: { Text("Plot") } footer: { Text("Basic FSI is on the net plot; premium and TDR on the gross plot.") }
        Section("Road in front of the plot") {
            HStack {
                Text("\(BuildFmt.fmtQty(road)) m").font(.title3.bold()).frame(width: 70, alignment: .leading)
                Slider(value: $road, in: 3...45, step: 0.5)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach([6.0, 9, 12, 15, 18, 24, 30, 36], id: \.self) { w in
                        Button("\(Int(w)) m") { road = w; Haptics.tap() }
                            .buttonStyle(.bordered).tint(road == w ? .orange : .gray).controlSize(.small)
                    }
                }
            }
        }
        Section {
            Picker("Planning authority", selection: $authorityRaw) {
                ForEach(FSIRules.Authority.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.navigationLink)
            Picker("Area", selection: $areaRaw) { ForEach(FSIRules.Area.allCases) { Text($0.title).tag($0.rawValue) } }.pickerStyle(.segmented)
            Picker("Use", selection: $residential) { Text("Residential").tag(true); Text("Non-residential").tag(false) }.pickerStyle(.segmented)
        } header: { Text("Where") } footer: {
            Text("Development authorities (MMRDA, PMRDA, NMRDA…): confirm which column your authority follows. Greater Mumbai uses DCPR-2034, not UDCPR — use “Any country” with your architect's figure.")
        }
        Section {
            Toggle("Premium FSI", isOn: $usePremium)
            Toggle("TDR", isOn: $useTDR)
            Toggle("Ancillary FSI (\(residential ? "60" : "80")%)", isOn: $useAncillary)
            TextField("ASR land rate per m² (optional, for premium cost)", text: $asr).keyboardType(.decimalPad)
        } header: { Text("Use") }
    }

    @ViewBuilder private var udcprResult: some View {
        let r = result
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Total built-up you can build").font(.caption).foregroundStyle(.secondary)
                Text(areaText(r.total)).font(.system(size: 30, weight: .heavy)).foregroundStyle(.orange)
                Text(r.gross > 0 ? "Effective FSI \(String(format: "%.2f", r.effectiveFSI)) on the gross plot" : "Enter the plot area")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let row = r.row {
                line("Basic FSI \(fmt(row.basic)) × net plot", r.basic)
                if usePremium { line("Premium FSI \(fmt(row.premium)) × gross plot", r.premium) }
                if useTDR { line("TDR \(fmt(row.tdr)) × gross plot", r.tdr) }
                line("Potential (\(fmt(row.potential)))", r.potential, bold: true)
                if useAncillary { line("Ancillary \(residential ? "60" : "80")% of potential", r.ancillary) }
            }
            if r.premiumCost > 0 {
                LabeledContent("Premium FSI charge (≈35% of ASR)", value: Money.format(r.premiumCost))
            }
            ShareLink(item: shareText(r)) { Label("Share calculation", systemImage: "square.and.arrow.up") }
        } header: { Text("Result · \(r.row?.label ?? "")") } footer: {
            Text("UDCPR-2020 Tables 6-G / 6-A (as amended), residential zone. Excludes special schemes (TOD, redevelopment incentives, SRA, cluster), stairs/lift areas, and local notifications. An estimate — confirm with your architect and the planning authority before buying land or filing plans.")
        }
        Section("Full table for this road") {
            ForEach(FSIRules.table(authority, area)) { row in
                HStack {
                    Text(row.label).font(.caption)
                    Spacer()
                    Text("\(fmt(row.basic)) + \(fmt(row.premium)) + \(fmt(row.tdr)) = \(fmt(row.potential))").font(.caption.monospacedDigit())
                }
                .foregroundStyle(row.label == r.row?.label ? .orange : .primary)
            }
        }
    }

    // MARK: World

    @ViewBuilder private var worldInputs: some View {
        let reg = FSIRules.regions.first { $0.id == region } ?? FSIRules.regions[0]
        Section {
            Picker("Country / region", selection: $region) { ForEach(FSIRules.regions) { Text($0.name).tag($0.id) } }.pickerStyle(.navigationLink)
            Text(reg.note).font(.caption).foregroundStyle(.secondary)
        } header: { Text("Where") }
        Section {
            TextField("Plot area (\(unit))", text: $plot).keyboardType(.decimalPad).font(.title3.weight(.semibold))
            TextField("\(reg.term) allowed (e.g. 2.5)", text: $ratio).keyboardType(.decimalPad)
            TextField("Bonus / incentive % (optional)", text: $bonus).keyboardType(.decimalPad)
            TextField("Site coverage % (optional)", text: $coverage).keyboardType(.decimalPad)
        } header: { Text("Your plot") } footer: { Text("Take the \(reg.term) from your zoning plan, plot affection plan or planning permission.") }
        let s = FSIRules.simple(plot: BuildData.number(plot), ratio: BuildData.number(ratio), bonus: BuildData.number(bonus), coverage: BuildData.number(coverage))
        Section("Result") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Gross floor area allowed").font(.caption).foregroundStyle(.secondary)
                Text(s.gfa > 0 ? String(format: "%.0f %@", s.gfa, unit) : "—").font(.system(size: 30, weight: .heavy)).foregroundStyle(.orange)
            }
            if s.footprint > 0 {
                LabeledContent("Building footprint", value: String(format: "%.0f %@", s.footprint, unit))
                LabeledContent("Floors needed (approx.)", value: String(format: "%.0f", s.floors))
            }
            ShareLink(item: "\(reg.term) \(ratio) on \(plot) \(unit) → \(String(format: "%.0f", s.gfa)) \(unit) gross floor area (iTeam Builder)") {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    // MARK: Helpers

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
    private func areaText(_ sqm: Double) -> String {
        guard sqm > 0 else { return "—" }
        return String(format: "%.0f m²  ·  %.0f sq ft", sqm, sqm * FSIRules.sqftPerSqm)
    }
    private func line(_ label: String, _ sqm: Double, bold: Bool = false) -> some View {
        HStack {
            Text(label).font(bold ? .subheadline.bold() : .subheadline)
            Spacer()
            Text(sqm > 0 ? String(format: "%.0f m²", sqm) : "—").font(.subheadline.monospacedDigit()).bold(bold)
        }
    }
    private func shareText(_ r: FSIRules.Result) -> String {
        """
        FSI (UDCPR-2020, \(authority.title), \(area.title), \(residential ? "residential" : "non-residential"))
        Plot \(String(format: "%.0f", r.gross)) m², net \(String(format: "%.0f", r.net)) m², road \(BuildFmt.fmtQty(road)) m
        Basic \(String(format: "%.0f", r.basic)) + Premium \(String(format: "%.0f", r.premium)) + TDR \(String(format: "%.0f", r.tdr)) + Ancillary \(String(format: "%.0f", r.ancillary))
        Total \(areaText(r.total))
        Estimate only — verify with the planning authority. (iTeam Builder)
        """
    }
}
