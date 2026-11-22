import Foundation

/// Floor Space Index / Floor Area Ratio rules.
/// Maharashtra UDCPR-2020 (as amended) Tables 6-G (non-congested) and 6-A (congested), residential zone, by abutting road width.
/// Basic FSI applies to the net plot (after road-widening / reservation / amenity deductions); premium FSI and TDR to the gross plot.
/// Ancillary FSI (on premium) = 60% of the potential for residential, 80% for non-residential.
/// Premium FSI is charged at 35% of the ASR (ready reckoner) land rate.
/// UDCPR does not apply to Greater Mumbai (DCPR-2034) and some special planning areas.
enum FSIRules {
    struct Row: Identifiable {
        let upTo: Double      // road width upper bound in metres (exclusive)
        let label: String
        let basic: Double
        let premium: Double
        let tdr: Double
        var id: String { label }
        var potential: Double { basic + premium + tdr }
    }

    enum Authority: String, CaseIterable, Identifiable {
        case corporation, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .corporation: "Municipal Corporation / CIDCO"
            case .other: "Council, Nagar Panchayat, Regional plan & other authorities"
            }
        }
    }

    enum Area: String, CaseIterable, Identifiable {
        case nonCongested, congested
        var id: String { rawValue }
        var title: String { self == .congested ? "Congested (gaothan)" : "Non-congested" }
    }

    static let mcNonCongested: [Row] = [
        .init(upTo: 9, label: "Below 9 m", basic: 1.10, premium: 0, tdr: 0),
        .init(upTo: 12, label: "9 m to below 12 m", basic: 1.10, premium: 0.50, tdr: 0.40),
        .init(upTo: 15, label: "12 m to below 15 m", basic: 1.10, premium: 0.50, tdr: 0.65),
        .init(upTo: 24, label: "15 m to below 24 m", basic: 1.10, premium: 0.50, tdr: 0.90),
        .init(upTo: 30, label: "24 m to below 30 m", basic: 1.10, premium: 0.50, tdr: 1.15),
        .init(upTo: .infinity, label: "30 m and above", basic: 1.10, premium: 0.50, tdr: 1.40),
    ]
    static let otherNonCongested: [Row] = [
        .init(upTo: 9, label: "Below 9 m", basic: 1.10, premium: 0, tdr: 0),
        .init(upTo: 12, label: "9 m to below 12 m", basic: 1.10, premium: 0.30, tdr: 0.30),
        .init(upTo: 15, label: "12 m to below 15 m", basic: 1.10, premium: 0.30, tdr: 0.60),
        .init(upTo: 24, label: "15 m to below 24 m", basic: 1.10, premium: 0.30, tdr: 0.70),
        .init(upTo: 30, label: "24 m to below 30 m", basic: 1.10, premium: 0.30, tdr: 0.90),
        .init(upTo: .infinity, label: "30 m and above", basic: 1.10, premium: 0.30, tdr: 1.10),
    ]
    static let mcCongested: [Row] = [
        .init(upTo: 9, label: "Below 9 m", basic: 1.50, premium: 0, tdr: 0),
        .init(upTo: 18, label: "9 m to below 18 m", basic: 2.00, premium: 0.30, tdr: 0.30),
        .init(upTo: 30, label: "18 m to below 30 m", basic: 2.00, premium: 0.30, tdr: 0.50),
        .init(upTo: .infinity, label: "30 m and above", basic: 2.00, premium: 0.30, tdr: 0.70),
    ]
    static let otherCongested: [Row] = [
        .init(upTo: 9, label: "Below 9 m", basic: 1.50, premium: 0, tdr: 0),
        .init(upTo: 18, label: "9 m to below 18 m", basic: 2.00, premium: 0.30, tdr: 0.10),
        .init(upTo: 30, label: "18 m to below 30 m", basic: 2.00, premium: 0.30, tdr: 0.20),
        .init(upTo: .infinity, label: "30 m and above", basic: 2.00, premium: 0.30, tdr: 0.20),
    ]

    static func table(_ a: Authority, _ area: Area) -> [Row] {
        switch (a, area) {
        case (.corporation, .nonCongested): mcNonCongested
        case (.other, .nonCongested): otherNonCongested
        case (.corporation, .congested): mcCongested
        case (.other, .congested): otherCongested
        }
    }
    static func row(_ a: Authority, _ area: Area, road: Double) -> Row {
        let t = table(a, area)
        return t.first { road < $0.upTo } ?? t[t.count - 1]
    }

    struct Result {
        var gross = 0.0, net = 0.0
        var basic = 0.0, premium = 0.0, tdr = 0.0, ancillary = 0.0
        var row: Row? = nil
        var premiumCost = 0.0
        var potential: Double { basic + premium + tdr }
        var total: Double { potential + ancillary }
        var effectiveFSI: Double { gross > 0 ? total / gross : 0 }
    }

    /// All areas in square metres.
    static func udcpr(gross: Double, deductions: Double, road: Double, authority: Authority, area: Area, residential: Bool, asrRate: Double,
                      usePremium: Bool = true, useTDR: Bool = true, useAncillary: Bool = true) -> Result {
        let r = row(authority, area, road: road)
        var out = Result()
        out.row = r
        out.gross = max(0, gross)
        out.net = max(0, gross - deductions)
        out.basic = out.net * r.basic
        out.premium = usePremium ? out.gross * r.premium : 0
        out.tdr = useTDR ? out.gross * r.tdr : 0
        out.ancillary = useAncillary ? out.potential * (residential ? 0.60 : 0.80) : 0
        out.premiumCost = asrRate > 0 ? out.premium * asrRate * 0.35 : 0
        return out
    }

    // MARK: Anywhere else in the world — the ratio comes from the local zoning plan.

    struct Region: Identifiable {
        let id: String
        let name: String
        let term: String
        let note: String
    }
    static let regions: [Region] = [
        .init(id: "in", name: "India (other states)", term: "FSI / FAR", note: "Set by the state DCR / building bye-laws and the local development plan; varies by zone and road width."),
        .init(id: "us", name: "United States", term: "FAR", note: "Set by the city zoning code per district (e.g. NYC zoning districts); bonuses for plazas or affordable housing."),
        .init(id: "uk", name: "United Kingdom", term: "Plot ratio", note: "No fixed national ratio — decided in planning permission against the local plan."),
        .init(id: "ae", name: "UAE (Dubai, Abu Dhabi)", term: "GFA / FAR", note: "Fixed per plot in the plot's affection plan / site plan from the master developer or municipality."),
        .init(id: "sa", name: "Saudi Arabia / GCC", term: "FAR / building ratio", note: "Per municipality zoning and plot permit."),
        .init(id: "sg", name: "Singapore", term: "Gross plot ratio (GPR)", note: "From the URA Master Plan for each land parcel."),
        .init(id: "hk", name: "Hong Kong", term: "Plot ratio", note: "From the Outline Zoning Plan and the Building (Planning) Regulations."),
        .init(id: "cn", name: "China", term: "Floor area ratio (容积率)", note: "Fixed in the land-use rights grant / planning conditions."),
        .init(id: "jp", name: "Japan", term: "Floor area ratio (容積率)", note: "Set by use zone; may be reduced by front road width."),
        .init(id: "au", name: "Australia / New Zealand", term: "FSR / plot ratio", note: "Local Environmental Plan (LEP) or district plan per zone."),
        .init(id: "de", name: "Germany / Europe", term: "GFZ (floor area ratio)", note: "Set in the Bebauungsplan / local land-use plan."),
        .init(id: "za", name: "South Africa / Africa", term: "Bulk / FAR", note: "Municipal zoning scheme per erf."),
        .init(id: "other", name: "Other / custom", term: "FAR", note: "Enter the ratio from your local zoning or planning permission."),
    ]

    struct Simple {
        var gfa = 0.0, footprint = 0.0, floors = 0.0
    }
    /// ratio × plot (+ bonus %), footprint from site coverage %, floors ≈ GFA ÷ footprint.
    static func simple(plot: Double, ratio: Double, bonus: Double, coverage: Double) -> Simple {
        var s = Simple()
        s.gfa = max(0, plot) * max(0, ratio) * (1 + max(0, bonus) / 100)
        s.footprint = coverage > 0 ? plot * coverage / 100 : 0
        s.floors = s.footprint > 0 ? (s.gfa / s.footprint).rounded(.up) : 0
        return s
    }

    static let sqftPerSqm = 10.7639
}
