"""Compile and exercise the production homepage layout preferences."""

from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HARNESS = r'''
import Foundation

nonisolated enum L10n {
    static func string(_ key: String) -> String { key }
}

@main struct Harness {
    static func main() throws {
        let defaults = HomeLayoutPreferences()
        precondition(defaults.modules.map(\.id) == HomeLayoutModule.allCases.map(\.id))
        precondition(defaults.quickActions.map(\.id) == HomeLayoutPreferences.quickActionIDs)
        precondition(defaults.usesCompactQuickActions)
        precondition(!HomeLayoutPreferences(compactQuickActions: false).usesCompactQuickActions)

        var draft = defaults
        draft.moveModule("charts", to: "quickActions")
        draft.moveQuickAction("similarSongs", to: "dailySongs")
        precondition(draft.modules.first?.id == "charts")
        precondition(draft.quickActions.first?.id == "similarSongs")
        precondition(defaults.modules.first?.id == "quickActions")
        precondition(defaults.quickActions.first?.id == "dailySongs")
        let unchanged = draft
        draft.moveModule("unknown", to: "charts")
        draft.moveQuickAction("dailySongs", to: "unknown")
        precondition(draft == unchanged)

        let first = HomeLayoutModuleConfiguration(id: "charts", isVisible: false, cardSize: .compact, presentation: .grid)
        let normalized = HomeLayoutPreferences(
            modules: [first, .init(id: "future-module"), .init(id: "charts")],
            quickActions: [.init(id: "similarSongs", isVisible: false, cardSize: .standard), .init(id: "future-action"), .init(id: "similarSongs")]
        )
        precondition(normalized.modules.count == HomeLayoutModule.allCases.count)
        precondition(normalized.modules.first == first)
        precondition(normalized.quickActions.count == HomeLayoutPreferences.quickActionIDs.count)
        precondition(normalized.quickActions.first?.isVisible == false)
        precondition(normalized.quickActions.first?.cardSize == .standard)
        precondition(normalized.normalized() == normalized)
        let encoded = try JSONEncoder().encode(normalized)
        let decoded = try JSONDecoder().decode(HomeLayoutPreferences.self, from: encoded)
        precondition(decoded == normalized)

        let future = Data(#"{"version":2,"modules":[{"id":"charts","isVisible":false,"cardSize":"future","presentation":"future"},{"id":"unknown"}],"quickActions":[{"id":"dailySongs","cardSize":"future"}]}"#.utf8)
        let migrated = try JSONDecoder().decode(HomeLayoutPreferences.self, from: future)
        precondition(migrated.module("charts")?.isVisible == false)
        precondition(migrated.module("charts")?.cardSize == .standard)
        precondition(migrated.module("charts")?.presentation == .shelf)
        precondition(migrated.module("unknown") == nil)
        precondition(migrated.quickAction("dailySongs")?.cardSize == nil)

        var hidden = defaults
        for var module in hidden.modules { module.isVisible = false; hidden.updateModule(module) }
        for var action in hidden.quickActions { action.isVisible = false; hidden.updateQuickAction(action) }
        precondition(hidden.normalized().modules.allSatisfy { !$0.isVisible })
        let roundTrip = try JSONDecoder().decode(HomeLayoutPreferences.self, from: JSONEncoder().encode(hidden))
        precondition(roundTrip == hidden)
        var restored = hidden.module("charts")!
        restored.isVisible = true
        hidden.updateModule(restored)
        precondition(hidden.module("charts")?.isVisible == true)
        print("Homepage defaults, draft moves, hidden items, normalization, legacy size, and codec checks passed")
    }
}
'''


class HomeLayoutChecks(unittest.TestCase):
    def test_layout_preferences(self):
        with tempfile.TemporaryDirectory(prefix="melox-home-layout-") as directory:
            directory = Path(directory)
            main = directory / "Harness.swift"
            executable = directory / "checks"
            main.write_text(HARNESS)
            subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(ROOT / "MeloX/Core/Settings/Application/HomeLayoutPreferences.swift"), str(main), "-o", str(executable)], check=True, cwd=ROOT)
            subprocess.run([str(executable)], check=True, cwd=ROOT, timeout=30)


if __name__ == "__main__":
    unittest.main()
