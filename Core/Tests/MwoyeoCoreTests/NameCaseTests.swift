import Foundation
import Testing
@testable import MwoyeoCore

/// A name that stands in running prose comes back from the engine in the case the engine likes ("fitfontsize"), and gets its spelling
/// back from the source (`TranslationCleanup.restoreSourceTokens`, round read117 item 3). The tokens of the source end at a letter, a
/// digit or an underscore: a full stop that closes the sentence is not part of the name, so a name at the end of a sentence is restored
/// like one in the middle. The sentences are the shapes of our own paper (tools/paper-own) and of the use-case bench's README scenes.
@Suite struct NameCaseTests {
    private func restored(_ translated: String, _ source: String) -> String { TranslationCleanup.restoreSourceTokens(translated, source: source) }

    @Test func aNameAtTheEndOfASentenceKeepsItsCase() {
        #expect(restored("깊이를 fitfontsize에 전달하세요.", "Pass the depth to fitFontSize.") == "깊이를 fitFontSize에 전달하세요.")
        #expect(restored("이 값은 stepduration입니다.", "The value is stepDuration.") == "이 값은 stepDuration입니다.")
        #expect(restored("자세한 내용은 TextFitter.fitfontsize를 참조하세요.", "See TextFitter.fitFontSize.") == "자세한 내용은 TextFitter.fitFontSize를 참조하세요.")
    }

    @Test func aNameFollowedByADashOrASlashKeepsItsCase() {
        #expect(restored("fitfontsize- 기반 방법", "fitFontSize- based method") == "fitFontSize- 기반 방법")
        #expect(restored("framediff/ 폴더", "FrameDiff/ folder") == "FrameDiff/ 폴더")
    }

    @Test func aWordIsNotTheStartOfAName() {
        // Paper bench p9: the word "core" of the sentence gave its case to the "Core" of a path that stands in it; p5: the word "i" to the
        // first letter of the dotted name of a line of code (the OCR's "I.asgignnent").
        let sentence = "The core of ScrollPredictor, Core/Sources/MwoyeoCore/ScrollPredictor swift, lines 31-68"
        #expect(restored("ScrollPredictor의 핵심인 Core/Sources/MwoyeoCore/ScrollPredictor swift, 31-68줄", sentence)
                == "ScrollPredictor의 핵심인 Core/Sources/MwoyeoCore/ScrollPredictor swift, 31-68줄")
        #expect(restored("핵심은 core 입니다", "the core") == "핵심은 core 입니다")
        #expect(restored("11 I.asgignnent a 저는 돌아갑니다", "11 I.asgignnent a i return") == "11 I.asgignnent a 저는 돌아갑니다")
        #expect(restored("a-class 모델", "an A model and a-class") == "a-class 모델")
        // The word is the end of a name too, whichever joiner stands before it.
        #expect(restored("Swift 파일 App.swift 입니다", "the Swift file App.swift") == "Swift 파일 App.swift 입니다")
        #expect(restored("fi 네트워크와 Wi-Fi", "the fi network and Wi-Fi") == "fi 네트워크와 Wi-Fi")
        #expect(restored("fi 와 A/Fi", "the fi and A/Fi") == "fi 와 A/Fi")
    }

    @Test func aWordNextToAMarkOfThePunctuationIsStillAWord() {
        // The full stop of a sentence, a comma, a slash with a space: not a name's joiner.
        #expect(restored("그것은 ios. 다음", "It is iOS. Next") == "그것은 iOS. 다음")
        #expect(restored("ios / macos 지원", "iOS / macOS support") == "iOS / macOS 지원")
        #expect(restored("ios와 macos", "iOS and macOS") == "iOS와 macOS")
    }

    @Test func aNameInTheMiddleIsAsBefore() {
        #expect(restored("fitfontsize를 호출하세요", "Call fitFontSize first") == "fitFontSize를 호출하세요")
        #expect(restored("(fitfontsize) 참조", "see (fitFontSize)") == "(fitFontSize) 참조")
        #expect(restored("v1.4.2 릴리스", "release v1.4.2") == "v1.4.2 릴리스")
        #expect(restored("src/app-main.swift 파일", "the file src/app-main.swift") == "src/app-main.swift 파일")
    }

    @Test func aSentenceThatEndsInAWordIsAsBefore() {
        // A word is no name: its full stop stays in the token, as the matching always took it (a word the engine capitalised stays so).
        #expect(restored("끝났습니다. Done.", "It is over. Done.") == "끝났습니다. Done.")
        #expect(restored("swift입니다.", "It is Swift.") == "swift입니다.")
        #expect(restored("readme를 참조하세요.", "See the readme.") == "readme를 참조하세요.")
    }

    @Test func theShapeOfAName() {
        // The engine writes a name in lowercase or capitalises its first letter (it opens a sentence): both go back to the source's spelling.
        for name in ["fitFontSize", "FrameDiff", "step_duration", "gemma3", "v1.4", "TextFitter.fitFontSize", "src/app", "iOS", "NASA"] {
            for engine in [name.lowercased(), name.prefix(1).uppercased() + name.dropFirst().lowercased()] {
                #expect(restored(engine + "입니다.", "It is \(name).") == name + "입니다.", "\(name) from \(engine)")
            }
        }
        for word in ["Swift", "readme", "Done", "ready"] {
            for engine in [word.lowercased(), word.prefix(1).uppercased() + word.dropFirst().lowercased()] where engine != word {
                #expect(restored(engine + "입니다.", "It is \(word).") == engine + "입니다.", "\(word) from \(engine)")
            }
        }
    }
}
