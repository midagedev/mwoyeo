ledgerline: a small ledger for the terminal
ledgerline reads plain text journals and prints the balance of every account. It needs no database and no account on a server. (inline: ledgerline)
Installation
Install the latest release with Homebrew and check the version.
$ brew install ledgerline (keep)
$ ledgerline --version (keep)
ledgerline 0.4.2 (keep:log)
Usage
Run it with --month 2026-09 to see one month only. Settings live in ~/.ledgerrc. (inline: --month 2026-09 ; ~/.ledgerrc)
# ~/.ledgerrc (keep:config)
currency = "EUR" (keep:config)
round_to = 2 (keep:config)
Contributing
Bug reports are welcome. Please run make test before you open a pull request. (inline: make test)
