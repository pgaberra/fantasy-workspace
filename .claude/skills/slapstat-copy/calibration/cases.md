# Calibration cases

Twenty SlapStat copy cases covering the main surfaces in `patterns.md`.

**Proposed** is the skill's answer, filled in on 2026-09-10, and is the thing under test. **Yours** is the human judgment: write `ok`, or the wording you would ship. Add **Why** only when you correct the proposal.

See `README.md` for scoring guidance.

---

## Landing and marketing

### 1. Shared projection, call-to-action heading

`src/app/shared-projection/shared-projection.html:215`

> This is one manager's projection

**Proposed:** keep

**Because:** Tells a visitor whose numbers these are before the page asks anything of them.

**Yours:**  
**Why:**
### 2. Shared projection, call-to-action body

`src/app/shared-projection/shared-projection.html:217`

> Build your own rankings around your league's scoring settings, or draft directly against this projection.

**Proposed:** small edit — *Build your own rankings, or draft against this projection.*

**Because:** "Around your league's scoring settings" is the landing page's claim again, and "directly" adds nothing. The two choices are what a visitor needs here.

**Yours:**  
**Why:**
### 3. Closing heading

`src/app/landing/landing.html:49`

> Build your draft board.

**Proposed:** small edit — *Build your rankings.*

**Because:** The draft board is Draft mode's own screen. What a reader builds before signing up is a projection and its rankings, and the line below already covers draft day.

**Yours:**  
**Why:**
### 4. Primary call to action

`src/app/landing/landing.html:24`

> Get started, it's free

**Proposed:** keep

**Because:** A short action plus the one fact that removes hesitation at the click.

**Yours:**  
**Why:**
### 5. Price note

`src/app/premium/premium.html:68`

> Billed monthly. Your exact price is confirmed at checkout.

**Proposed:** small edit — *Your exact price is confirmed at checkout.*

**Because:** The page header already says it is one monthly plan. The second sentence is the one the reader needs when no price is shown.

**Yours:**  
**Why:**
## Premium

### 6. Premium perk, title and description

`src/app/shared/premium/premium-perks.ts:28`

> AI projection
>
> Every player projected for the 2026-27 season with our AI model.

**Proposed:** small edit — *Every player projected for the 2026-27 season.*

**Because:** "with our AI model" adds little and repeats the title. A stronger version may depend on what free users get as a starting point, which should be verified before changing the claim.

**Yours:**  
**Why:**

### 7. Premium perk with no description

`src/app/shared/premium/premium-perks.ts:36`

> Custom range on Who's Hot

**Proposed:** keep

**Because:** The title already communicates the benefit. Adding a description risks stating the obvious.

**Yours:** ok  
**Why:**

### 8. Premium perk, the filler slot

`src/app/shared/premium/premium-perks.ts:42`

> More Premium features
>
> New Premium features will be added regularly.

**Proposed:** remove

**Because:** A feature list should describe what users get now. Future additions do not need to appear as a feature of their own.

**Yours:** *New features first* / *Get new Premium features as they are released.*  
**Why:** A perk for upcoming Premium features is fine as its own item.

### 9. Free feature, second in the list

`src/app/shared/premium/premium-perks.ts:52`

> Live draft board and post-draft rankings

**Proposed:** small edit — *Draft mode and post-draft team rankings*

**Because:** `Draft mode` is the feature's name, and "live draft" is on the avoid list. "Rankings" alone reads as player rankings; these rank the teams.

**Yours:**  
**Why:**
## Empty and error states

### 10. Empty state for imports

`src/app/projection-create/projection-create.html:108`

> No imports yet. Paste a SlapStat share link below.

**Proposed:** keep

**Because:** Says what is missing and what to do next, and the field it points to is directly below.

**Yours:**  
**Why:**
### 11. Invalid reset link, title and message

`src/app/auth/reset-password/reset-password.html:10`

> Invalid link
>
> This password reset link is missing or invalid.

**Proposed:** remove the message; keep *Invalid link*.

**Because:** The title names the problem and the link below names the fix. The sentence repeats the title in longer words.

**Yours:**  
**Why:**
### 12. Payment failure

`src/app/pay/pay.html:5`

> Something went wrong while opening the payment window. Nothing was charged.

**Proposed:** small edit — *Couldn't open the payment window. Nothing was charged.*

**Because:** The first sentence should name what failed. The second sentence answers the important payment question.

**Yours:**  
**Why:**

### 13. Verification email failed to send

`src/app/shared/unverified-banner/unverified-banner.html:23`

> Couldn't send the verification email. Please try again.

**Proposed:** small edit — *Couldn't send the verification email.*

**Because:** Avoid telling the reader to retry unless retrying is known to be useful. The nearby action already provides the retry path.

**Yours:**  
**Why:**

## Banners and notices

### 14. Verification email sent

`src/app/shared/unverified-banner/unverified-banner.html:5`

> Verification email sent. Check your inbox or spam folder.

**Proposed:** keep

**Because:** It gives the two useful facts and prevents a common support question.

**Yours:**  
**Why:**

### 15. Starting point method note

`src/app/shared/starting-point-preview/starting-point-preview.html:60`

> Each player is projected from his last three seasons, weighted toward the most recent, adjusted for age and set against how the league is scoring now. Shot quality, hits, blocks and faceoffs come from MoneyPuck. Data © MoneyPuck.com.

**Proposed:** rewrite — *Each player is projected from his last three seasons, weighted toward the most recent. Projections are adjusted for age and for how the league is scoring now. Shot quality, hits, blocks and faceoffs come from MoneyPuck. Data © MoneyPuck.com.*

**Because:** The first sentence stacks four method steps. Splitting it keeps every fact. The MoneyPuck credit is required by its terms and stays as written.

**Yours:**  
**Why:**
### 16. Checkout loading message

`src/app/pay/pay.html:13`

> This may take a moment. Please keep this page open.

**Proposed:** small edit — *Keep this page open.*

**Because:** "This may take a moment" is reassurance the spinner already gives. The instruction is the part that matters.

**Yours:**  
**Why:**
### 17. Player pool updated

`src/app/shared/player-pool-notice/player-pool-notice.html:13`

> Your existing projections are unchanged. New players start with last season's stats, or zero for projections built from scratch. Review them before your draft.

**Proposed:** small edit — remove the third sentence.

*Your existing projections are unchanged. New players start with last season's stats, or zero for projections built from scratch.*

**Because:** The first two sentences answer useful questions. The final sentence tells a fantasy manager to do something they already know to do.

**Yours:**  
**Why:**

## Dialogs, tooltips and forms

### 18. Dialog, title and body

`src/app/draft-projection/full-season-dialog/full-season-dialog.html:9`

> Set to 84 games?
>
> Set every skater to 84 games. Goalie totals stay unchanged.

**Proposed:** small edit — body becomes *Goalie totals stay unchanged.*

**Because:** The body should add information rather than repeat the title.

**Yours:**  
**Why:**

### 19. Help text at a setting

`src/app/draft-projection/player-projections-table/league-settings-menu/league-settings-menu.html:52`

> League size and roster slots affect player values in your rankings.

**Proposed:** keep

**Because:** Explains what the settings change, which the fields themselves cannot show. The code confirms it: league size and roster slots set the player pool that values are measured against.

**Yours:**  
**Why:**
### 20. Sign-up subtitle

`src/app/auth/register/register.html:3`

> Join SlapStat today

**Proposed:** remove

**Because:** "today" adds artificial urgency, and the rest repeats the purpose of the page. The form does not need a marketing sentence here.

**Yours:**  
**Why:**

---

## Benchmark notes

- Cases **1, 4, 7, 8, 10, 11, 14, 19 and 20** deliberately test whether the skill can keep good copy or remove unnecessary copy instead of rewriting it.
- Case **6** deliberately tests whether the skill asks for a missing product fact instead of inventing one.
