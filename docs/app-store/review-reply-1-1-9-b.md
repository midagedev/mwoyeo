# Reply to App Review, submission 34b9a7a4 (2.4.5(iii), sent with the next 1.1.9 build)

Draft for the App Store Connect reply to the message of 2026-11-05 (docs/app-store/review-2026-11-05.md).

---

Hello,

Thank you for the review. We uploaded a new build of 1.1.9 that fixes this.

Guideline 2.4.5(iii): MwoyeoReader-lines and MwoyeoReader-docs are XPC services in the app bundle. They read text for
the running app only. Before, they stayed after the app quit. Now each one exits within one second after its last
connection to Mwoyeo closes. This covers Quit, Force Quit and a crash. The third service, MwoyeoScript, works the same
way. We checked that no process of the app is running three seconds after it quits.

Best regards,
Hyeoncheol Kim
