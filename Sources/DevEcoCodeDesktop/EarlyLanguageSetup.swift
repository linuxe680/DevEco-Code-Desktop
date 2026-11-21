import Foundation

private let earlyLanguageSetup: Void = {
    let defaults = UserDefaults.standard
    let language = defaults.string(forKey: "appLanguage") ?? "zh-Hans"
    if language == "system" {
        defaults.removeObject(forKey: "AppleLanguages")
    } else {
        defaults.set([language], forKey: "AppleLanguages")
    }
}()
