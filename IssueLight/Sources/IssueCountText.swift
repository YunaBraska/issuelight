import Foundation

enum IssueCountText {
    static func attention(_ count: Int, locale: Locale = .current) -> String {
        switch count {
        case 0:
            return AppLocalization.string("Keine Probleme benötigen Aufmerksamkeit", locale: locale)
        case 1:
            return AppLocalization.string("1 Problem benötigt Aufmerksamkeit", locale: locale)
        default:
            return AppLocalization.string("\(count) Probleme benötigen Aufmerksamkeit", locale: locale)
        }
    }

    static func covered(_ count: Int, locale: Locale = .current) -> String {
        count == 1
            ? AppLocalization.string("1 Problem quittiert oder in Wartungszeit", locale: locale)
            : AppLocalization.string("\(count) Probleme quittiert oder in Wartungszeit", locale: locale)
    }

    static func sourceStatus(_ count: Int, locale: Locale = .current) -> String {
        switch count {
        case 0:
            return AppLocalization.string("keine Probleme", locale: locale)
        case 1:
            return AppLocalization.string("1 Problem", locale: locale)
        default:
            return AppLocalization.string("\(count) Probleme", locale: locale)
        }
    }
}
