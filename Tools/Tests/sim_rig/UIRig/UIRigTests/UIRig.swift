import XCTest

/// Drives the installed app through real touches, for the things the
/// command channel cannot reach: menus, alerts, navigation.
///
/// Steps come from `RIG_STEPS`, separated by `;`:
///
///     tap:<label>      first hittable element with that label or text
///     tapxy:<x>,<y>    a point, as fractions of the screen
///     hold:<label>     long press
///     swipe:<up|down|left|right>
///     wait:<seconds>
///     shot:<name>      screenshot to <RIG_OUT>/<name>.png
///     tree:<name>      the accessibility tree to <RIG_OUT>/<name>.txt
///
/// The app is attached to as it is, never relaunched. See `rig.sh ui`.
struct MissingElement: Error, CustomStringConvertible {
    let label: String
    var description: String { "no hittable element labelled \(label)" }
}

final class UIRig: XCTestCase {
    func testRun() throws {
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication(
            bundleIdentifier: environment["RIG_BUNDLE"] ?? "azki.moye.MeloX"
        )
        let output = URL(
            fileURLWithPath: environment["RIG_OUT"] ?? "/tmp/melox-rig"
        )
        app.activate()

        for step in (environment["RIG_STEPS"] ?? "").split(separator: ";") {
            let parts = step.split(separator: ":", maxSplits: 1)
            let action = String(parts[0])
            let argument = parts.count > 1 ? String(parts[1]) : ""
            switch action {
            case "tap":
                try element(argument, in: app).tap()
            case "hold":
                try element(argument, in: app).press(forDuration: 1)
            case "tapxy":
                let values = argument.split(separator: ",").compactMap {
                    Double($0)
                }
                guard values.count == 2 else { break }
                app.coordinate(
                    withNormalizedOffset: CGVector(dx: values[0], dy: values[1])
                ).tap()
            case "swipe":
                switch argument {
                case "up": app.swipeUp()
                case "down": app.swipeDown()
                case "left": app.swipeLeft()
                default: app.swipeRight()
                }
            case "wait":
                Thread.sleep(forTimeInterval: Double(argument) ?? 1)
            case "shot":
                try XCUIScreen.main.screenshot().pngRepresentation.write(
                    to: output.appendingPathComponent("\(argument).png")
                )
            case "tree":
                try app.debugDescription.write(
                    to: output.appendingPathComponent("\(argument).txt"),
                    atomically: true,
                    encoding: .utf8
                )
            default:
                XCTFail("unknown step \(step)")
            }
        }
    }

    private func element(
        _ label: String,
        in app: XCUIApplication
    ) throws -> XCUIElement {
        // An exact label wins: "播放" must not land on "播放队列".
        let exact = NSPredicate(
            format: "label == %@ OR identifier == %@",
            label, label
        )
        let partial = NSPredicate(format: "label CONTAINS %@", label)
        let elements = app.descendants(matching: .any)
        let deadline = Date().addingTimeInterval(5)
        repeat {
            for predicate in [exact, partial] {
                let candidates = elements.matching(predicate)
                    .allElementsBoundByIndex
                if let hittable = candidates.first(where: \.isHittable) {
                    return hittable
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        throw MissingElement(label: label)
    }
}
