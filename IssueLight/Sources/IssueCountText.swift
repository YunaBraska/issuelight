enum IssueCountText {
    static func attention(_ count: Int) -> String {
        switch count {
        case 0:
            return "Keine Probleme benötigen Aufmerksamkeit"
        case 1:
            return "1 Problem benötigt Aufmerksamkeit"
        default:
            return "\(count) Probleme benötigen Aufmerksamkeit"
        }
    }

    static func covered(_ count: Int) -> String {
        count == 1
            ? "1 Problem quittiert oder in Wartungszeit"
            : "\(count) Probleme quittiert oder in Wartungszeit"
    }

    static func sourceStatus(_ count: Int) -> String {
        switch count {
        case 0:
            return "keine Probleme"
        case 1:
            return "1 Problem"
        default:
            return "\(count) Probleme"
        }
    }
}
