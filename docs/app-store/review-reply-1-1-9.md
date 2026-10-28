# Reply to App Review, submission 34b9a7a4 (sent with 1.1.9)

Draft for the App Store Connect reply. The privacy policy quoted below is
https://github.com/midagedev/mwoyeo/blob/main/docs/PRIVACY.md ("Screen Recording" section).

---

Hello,

Thank you for the review. We submitted version 1.1.9, which addresses both issues.

Guideline 5.1.1(iv): the button in our welcome window that comes before the system prompt now says "Continue" (it said
"Allow"). The menu bar notice and the lens hint no longer say "Allow" either. While Screen Recording is off, the
welcome window says why the app needs it, and Continue opens System Settings.

Guideline 2.1, screen recording:

1. Features that use screen recording:
   - A lens: a window the person draws over text. It captures only the area it covers, while it is open, reads the
     text there and draws the translation over it.
   - Whole screen while held: while the person holds Control-Option-P, the app takes one picture of the display under
     the pointer, translates its text and draws the translation over it. It is gone when the keys are released.
   - Window positions, so a lens stays on its window.
2. Data collected: the pixels of those areas and the text Apple Vision finds in them, on the Mac. No video, no audio.
3. Purpose: only to show the translation over the text. It is not used for analytics, advertising, tracking,
   profiling or training.
4. Third parties: none. Screen images and the text read from them never leave the Mac. This version has no
   translation engine off the Mac: translation uses Apple's Translation framework, Apple Intelligence, or a server
   the person runs on the same Mac (localhost).
5. Storage: in memory only, while needed to show a translation; gone when the app quits at the latest. Nothing is
   written to disk unless the person turns on saving transcripts or saves a lens image, to a folder they choose.
6. Privacy policy: https://github.com/midagedev/mwoyeo/blob/main/docs/PRIVACY.md, section "Screen Recording" (also
   "What is saved to files").
7. Quoted language:
   - "Mwoyeo asks for macOS Screen Recording permission. It uses it for these features, and for nothing else"
   - "What it collects: the pixels of those areas and the text that Apple Vision finds in them, on your Mac. It
     records no video and no sound."
   - "Why: only to show the translation over the text. Screen recording data is not used for analytics, advertising,
     tracking, profiling or training, and it is never sold."
   - "Sharing: screen images never leave your Mac. In the Mac App Store version, nothing read from the screen leaves
     your Mac: that version has no translation engine off this Mac."
   - "Storage and retention: screen images and the text read from them are kept in memory only, while Mwoyeo needs
     them to show a translation, and are gone when the app quits at the latest. Nothing from the screen is written to
     disk, unless you turn on saving transcripts or save a lens image yourself"

Best regards,
Hyeoncheol Kim
