# W041 buying options verification

Recorded on 6 November 2026 for W041, [issue #69](https://github.com/jorgerodrigues/ure/issues/69), the ninth Rework story. The branch started at `aebd6c2` on `w002-recoverable-library`, which includes W033 to W040. The story was paused after five Codex rounds so that the edit queue could land first, and it was then rebased onto `51c3daa`, "Save every change through one ordered edit queue". The latest migration there is still `v26-parts`, so this story adds `v27-buying-options`.

## Design source

The session read the live Paper file Ure, page "Rework · Simple", token hash `b9b53808`. It read "3 Parts", "3b Part, after Buy" and "3c Mark as bought", the Parts section of "2 Job", and the Part block and the decided questions on "1 Model", with the JSX and computed-style tools, and compared them with the window check's renders.

The views follow the JSX values. On the part page, "Mark as Bought…" is a capsule button in the accent colour at the end of the state line, 28 pt high with 13 pt semibold text. The Options heading is 17 pt bold with "Price with shipping" in 13 pt on the right, 12 pt above the options. Each option is a card with a 12 pt radius and a thin outline, 14 pt by 16 pt inside, 8 pt from the next. It starts with the supplier's initial in 13 pt bold on a 32 pt white tile with an 8 pt radius, 14 pt from the supplier in 15 pt semibold, with "Lowest" beside it in 11 pt semibold accent text on the accent colour at 10 percent, 18 pt high with a 5 pt radius. The note is 13 pt in the secondary colour. On the right, at least 150 pt wide, the price with shipping is 17 pt semibold, such as "≈ €21.40", over a 12 pt line such as "£12.90 + £5.50 shipping" or "free shipping". Under the cards, "Paste a link to add an option" sits in a 52 pt box with a dashed outline and a 12 pt radius, with a 14 pt plus, and a 12 pt line under it says how estimates work. The Bought section has the 17 pt heading with "Open listing" in 13 pt accent text, four columns 32 pt apart with 11 pt medium labels over 15 pt values in 24 pt rows, what you paid in semibold, the states on the quiet fill with a 12 pt radius, 14 pt by 16 pt inside, with 8 pt dots, and a 40 pt line after a thin rule for the options kept. The popover is 420 pt wide with 18 pt inside and 14 pt between groups. Its rows are 36 pt high with a 16 pt radio, the supplier in 15 pt, the price and shipping in 12 pt secondary, and the amount in 15 pt, semibold when chosen. Its fields are 32 pt high with an 8 pt radius, a thin outline, the currency's symbol before the amount, and an accent ring while you type. The shipping field is 110 pt and "Charged to you" 140 pt wide, and Cancel and Mark as Bought are 28 pt capsules. On the job's lines the price column is 84 pt, in 15 pt, with "from" in 12 pt over a price to buy, and "Compare 3 options" is a 12 pt accent link. In the Parts list the amount is 12 pt on the right of the row.

### Differences found and fixed

1. The breakdown under an option's price, such as "£12.90 + £5.50 shipping", wrapped onto two lines in a narrow window. The price column now takes the room it needs, at least 150 pt, as on "3 Parts".
2. The line that says how typing works wrapped under the narrow price and shipping fields. Those two fields leave it out.
3. Two suppliers whose names start alike got the same colour on their initial. The colour now comes from a hash of the whole name, so "Cousins UK", "eBay" and "Esslinger" differ, as on "3 Parts".
4. The note under the options said "in Euro". It says "in EUR", as on "3 Parts".
5. While the queue was stopped, Settings asked for a window 1,071 pt wide, because the failure bar's message is one long line. The bar is now as wide as the form, 560 pt, and its message wraps to up to six lines there.

### Differences left on purpose

1. Amounts follow the Mac's region. This Mac is set to Denmark, so the renders say "21,34 €" where the artboards say "€21.40".
2. The test host's windows are never key, so "Mark as Bought…" and the popover's default button render grey in the captures. In the app they are in the accent colour.
3. A grouped form draws only its first screen in the test host, so the Money section is also rendered on its own.

## What changed

- Migration `v27-buying-options` in `Ure/Persistence/BuyingMigration.swift` turns each saved link into a row of the new `partOption` table, with the same ID, part, place and times, the link's host as its supplier, and no price. Then it drops `partLink`. The `part` table gains what was bought: `paid`, `paidCurrency`, `boughtPrice`, `boughtShipping`, `boughtCurrency`, `boughtFrom`, `boughtURL` and `boughtOptionID`. The database refuses a purchase on a Needed part. Two new tables hold the money settings: `librarySetting` for the chosen home currency and `currencyRate` for a rate per home currency and currency. Money is stored as decimal text with an ISO code and checks, and read as Swift `Decimal`, never as floating point.
- The money types are in `Ure/Features/Money/`. `MoneyEntry` reads an amount as typed on a receipt, such as "12.90", "£12.90" or "12,90 €". `ExchangeRates` makes the ≈ estimate in the home currency, rounded to its decimals. `PartPricing` and `PartMoneyWording` give Lowest, "from €21.40" and "€42.40 paid". The job's paid total adds only the amounts charged in the home currency. Rates are only ever typed by you.
- Every buying change is an edit on the library's one queue, as the edit queue's hand-over asks. `PartEdit` gains `addOption`, `setOption`, `removeOption`, `restoreOption` and `markBought`, and a new `MoneyEdit` has `setHomeCurrency` and `setRate`. Each service call reads the row it changes in its own transaction and returns what was there before, and `LibraryEditor` builds the inverse from it. Undo of a price, the shipping or the currency puts back all three as stored, because a first amount also sets the option's currency. Mark as Bought's inverse is the state before with no purchase. A rate's inverse is the rate before for the same home currency. Choosing the home currency has no Undo.
- The option fields are `FactField`s on the queue. They read the typed text with the Mac's locale and submit exact amounts, so the services never parse text. A mark typed with an amount must be the option's currency. Only the currency's pop-up changes the currency, as a command with its own Undo step, and a currency that can't take an amount, such as the yen for 12.90, is refused at once. Delete Option is an `endedRecord`, so an option takes no edits while its deletion saves.
- Mark as Bought opens once the typing before it has saved and the queue is idle, so it offers the price you just typed. It says so when a price did not save or the queue is stopped. It submits and closes, as every command does, and a failed save shows in the window's failure bar.
- Settings follows the money settings of the library that is open, through `RestoreState.observeSettingsMoney()`, also after a restore made while the main window is closed. While a restore runs, the Money section takes no edits. While the queue is stopped, Settings shows the same failure bar as the main window, with Try Again and Discard Unsaved Changes….
- The views follow "3 Parts", "3b Part, after Buy" and "3c Mark as bought": the Options section with cards and the paste box, the Bought section, the popover, the job's price column and Parts heading, the Parts list prices, and Money in Settings. A click on a Needed pill opens Mark as Bought, as "3c" says.
- The specification, the README, the recovery harness and the performance fixture are updated.

## Design rules

Before each fix, the findings so far were put into groups, one for each rule of the design that they broke. Each rule has one place in the code that makes it true.

1. Every buying change saves through the library's one queue, in the order you made it, and Mark as Bought reads the options only once the changes before it have saved. Before the queue, the popover read a price still being typed, closed before its own save finished, and offered a stored price after a failed save. The place: `PartState`'s commands submit at once, and `PartState.savedOptions(of:)` flushes the typing, waits for the queue, and gives nil while the queue is stopped. The tests: `markAsBoughtOffersThePriceJustTypedAndWaitsBehindAFailedSave` and `markAsBoughtFromAnOptionOrdersThePartAndUndoPutsItBack`.
2. Undo comes from the stored data. A price, the shipping and the currency share one currency, and a first amount sets it, so their Undo puts back all three as stored. A rate's Undo keeps the home currency its field was made for. Before the queue, Undo replayed a field's text against whatever was current, so Undo of "£10" could leave the option in pounds and a rate's Undo could reach another home currency. The place: `PartOptionFact.stored(in:)` and the `setRate` case in `LibraryEditor`. The tests: `anOptionTakesNoEditsWhileItsDeletionSavesAndItsUndoComesFromTheStoredData`, `anOptionsCurrencyNeverRelabelsAnAmountAndUndoPutsItBack` and `aRateFieldsUndoStaysWithItsHomeCurrency`.
3. An amount is read in the option's currency, and only the currency's pop-up changes that currency. Text that a new currency makes valid saves without being typed again. The place: `PartOptionFacts.amountRule` and `saveAmountsNow()`, which `PartState.chooseCurrency` and `homeCurrencyChanged` call. The tests: `anOptionsCurrencyNeverRelabelsAnAmountAndUndoPutsItBack` and `anOptionWithoutACurrencyFollowsANewHomeCurrency`.
4. Settings shows and edits the money settings of the library that is open, and none while a restore replaces it. The place: `RestoreState.settingsMoney` and `observeSettingsMoney()`. The tests: `settingsShowTheRestoredLibrarysCurrencyAndRates` and `settingsTakeNoMoneyEditsWhileARestoreReplacesTheLibrary`.

## App check

Sessions on this Mac have no Screen Recording or Accessibility permission, so the app check is the local-only window check that the user accepted for the Rework stories. `W041-LocalBuyingAppCheck.swift` in the hand-over folder hosts the real `LibraryRootView` with every session state in a window of the test host, on a library made at `v26-parts` with five saved links. It was copied into `UreTests` for one run at a time and removed after each. It is not committed. The last run passed on the code of the final commit.

It reads the migrated database: `v27-buying-options` is the last migration, the five links are five options with their hosts as suppliers, `partLink` is gone, and the integrity and foreign key checks pass. Then it renders, and reads each field's accessibility label and value:

- the options with Lowest, the ≈ estimate, and an option in dollars with no rate,
- an option's fields while you type a price and shipping, and after they save,
- the paste box, with ⌘Z of the pasted option and a pasted text that is not a link,
- the Mark as Bought popover from an option, from "Somewhere else" and from just an amount, a field's message after you leave it, Esc that changes nothing, and typing "£" in the real popover,
- Return that marks the part bought, the part after Buy as on "3b", ⌘Z and ⇧⌘Z,
- the job's Parts heading, "1 to buy · 42,40 € paid", its lines with "from 21,34 €" and "Compare 3 options", and the Parts list,
- the rates in Settings, and Settings with the failure bar while a rate fails to save, which Try Again then saves,
- the part page in dark appearance.

The renders are in `~/Developer/test-assets/jorge-w041-buying-dd17e0/queue-check/`.

The Debug build also ran on its own with `URE_TESTING=1` and a new test library id, on a copy of the same `v26-parts` library. It upgraded the library to `v27-buying-options` with the five options, kept running, and quit on `kill -TERM`.

## Codex review

Codex ran with `codex exec review --ignore-user-config` over the whole branch. Rounds one to five ran before the pause, on the code without the queue, and found sixteen problems and two more about Settings during a restore. All were fixed with a test. Rounds one to five are listed in `W041-paused.md` in the hand-over folder. Eight of them were about save order or Undo, and the queue's rebuild now covers them by rules 1 and 2. Five were about money and parsing, and their fixes and tests stay.

After the rebase onto the queue, the steps allowed three more rounds, with the user's rule that corner cases such as a failed disk write, a slow save or two quick actions while a save runs are acceptable.

- Round six found one problem that normal use hits. A price refused for its mark, such as "£10" on an option in euros, stayed unsaved after you chose GBP as its message asks, so Mark as Bought would not open. Rule 3 now saves it. The test is in `anOptionsCurrencyNeverRelabelsAnAmountAndUndoPutsItBack`, and the same holds for a new home currency in `anOptionWithoutACurrencyFollowsANewHomeCurrency`.
- Round seven found nothing.
- Round eight ran on `689131c`, after the Settings layout fix that the window check found, and found nothing.

No finding was declined, and no corner case came up after the rebase.

## Executed checks

Development Mac: Apple silicon, macOS 27.3, Xcode 27.2. The SDK cache workaround `SDK_STAT_CACHE_ENABLE=NO` was passed where the steps run `xcodebuild` directly.

| Check | Result |
| --- | --- |
| `make check` | Passed on `689131c`: lint, unsigned Debug build, and 427 of 427 unit test runs |
| `make release` | Passed on `689131c`, unsigned optimized Release build |
| Isolated running app | The Debug build ran with `URE_TESTING=1` and a new test library id on a copy of a `v26-parts` library with five saved links. It upgraded the library to `v27-buying-options`, kept running, and quit on `kill -TERM`. The upgraded database had five options, no `partLink`, and passed the integrity and foreign key checks |
| Local window check | Passed on the code of `689131c`. It was copied into `UreTests` for each run and removed after it |
| No network for rates | `NoNetworkRatesTests` checks that the app has no network entitlement and makes no URL request while you set rates and mark a part bought |
| GitHub CI | Off since 6 November, as the user asked while the app is a prototype. The gate in its place is `make check` and `make release` on the final code |

## Not verified

- The real Settings window was not seen, because sessions have no Screen Recording permission. The window check rendered `SettingsView` in a window of the test host instead, with and without the failure bar.
- The currency pop-up's menu was not opened in a window. The tests drive `PartState.chooseCurrency`, which the menu calls.
