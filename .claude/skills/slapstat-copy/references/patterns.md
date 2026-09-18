# SlapStat copy patterns

Examples of before/after copy from SlapStat. These examples show judgment and preferred direction, not reusable templates. Do not copy their wording unless it fits the context naturally.

## Hero

### Before
> Prepare for the upcoming 2026-27 NHL fantasy season. Create a projection tailored to your league — every player ranked to your exact scoring settings. Try the editor right here, no account needed.

### After
> Rankings built around your league's scoring settings. Works for points and category leagues. Try the editor below, no account needed.

**Pattern:** Say what the product does. Add useful information. Remove repetition and filler.

## Feature cards

Write feature cards as a set. Keep them parallel in tone and length.

### Card 1

**Before**
> Tailor projections directly to your league settings, whether you play points or categories. No more manual formulas or messy spreadsheets.

**After**
> Set your league's scoring and adjust your projections without wrestling with formulas or spreadsheets.

**Pattern:** Do not restate the title in the description.

### Card 2

**Before**
> Comparing player value in category leagues used to be guesswork. Our Z-Score ranking combines all your league's categories into a single, easy-to-read board.

**After**
> Compare players using your league's scoring settings. Z-Scores put different categories on the same scale.

**Pattern:** Start with the useful fact. Avoid setup sentences and unnecessary company-centric wording.

### Card 3

**Before**
> Run your draft in real-time with an interactive draft board, track picks seamlessly, and see instant post-draft power rankings to compare every team.

**After**
> Use your projection as a live draft board, track every pick, and see how the teams stack up as the draft unfolds.

**Pattern:** Avoid cramming several claims into one sentence. Do not use promotional filler such as "seamlessly".

## Closing CTA

### Before
> **Get your draft board ready.** Create a free account to save your projections and take them to draft day.

### After
> **Get your draft board ready.** Create a free account to keep your projections and use them in Draft Mode.

**Pattern:** The body should add information rather than repeat the heading.

## Pricing and Premium

Keep the value proposition concrete. Do not sell a generic feeling of "more power".

### Feature descriptions

**Prefer**
> **The AI projection**  
> Projected stats for the 2026-27 season, ready to use or edit.

**Prefer**
> **Custom range**  
> Analyze any range from the last 10 games to the full season. Free accounts include the last 5.

**Prefer**
> **New features first**  
> Get new Premium features as they are released.

**Pattern:** Name the actual feature and explain what the user gets. Avoid vague benefits such as "unlock premium features" when the specific feature can be named.

### Premium framing

**Avoid**
> Support SlapStat and unlock premium features as they roll out.

**Prefer**
> Premium includes the AI projection, additional game ranges on Who's Hot, and new Premium features as they are released.

Keep pricing copy factual. Do not invent scarcity, deadlines, or guarantees.

## The tagline

The current tagline is:

> Top-Shelf Tools for Fantasy Hockey Managers

Do not rewrite or replace brand-level copy unless explicitly asked. A tagline change is a brand decision, not a routine copy edit.

The page title does not need to include the tagline. Leaving it out is not a tagline change.

## Page title and social tags

`<title>`, meta description, `og:title`, `og:description`, `twitter:title` and `twitter:description` should be reviewed together.

### Before
> SlapStat - Top-Shelf Tools for Fantasy Hockey Managers  
> Top-shelf tools for fantasy hockey managers: rankings and projections tuned to your league's scoring settings. Connect your Yahoo league and play smarter.

### Prefer
> SlapStat: Fantasy Hockey Rankings for Your League  
> Project every NHL player and rank them using your league's scoring settings. Sync from Yahoo or ESPN, then draft from the same rankings.

**Pattern:** Lead with what SlapStat is or does. Prefer concrete product terms over generic claims such as "play smarter".

## Headings

A heading should tell the reader what the section contains.

**Prefer**
> Refunds  
> League setup  
> Draft summary  
> Questions  
> Scoring settings

**Avoid**
> Good to know  
> Everything you need to know  
> Get ready to dominate  
> A few things first

**Pattern:** If the same heading could sit above several unrelated sections, it is probably too generic.

## Buttons

Use a short verb phrase in sentence case. Navigation and footer links are the exception: title case (*Send Feedback*, *Sign In*). Name the object when needed to make the action clear.

**Prefer**
> Create projection  
> Save  
> Import league  
> Re-sync settings  
> Manage subscription  
> Start draft  
> Subscribe

**Avoid**
> Create your new projection  
> Click here to import your league  
> Manage your subscription settings  
> Submit  
> OK

Progress text should reuse the button verb:
> Create projection → Creating…  
> Re-sync settings → Re-syncing…

## Form labels and validation

Labels are short nouns or noun phrases in sentence case, with no colon.

**Prefer**
> Projection name  
> League size  
> Draft order

A placeholder should not contain information the user needs, because it disappears on focus.

### Validation

**Already right**
> Email is required.  
> Enter a valid email address.  
> Password does not meet the requirements below.  
> Passwords do not match.

**Pattern:** Name the field or problem directly. Do not scold the user or repeat a validation rule already shown in the UI.

## Empty states

Say what is missing, then give the next useful action when one is needed.

**Already right**
> No players match. Try a wider game range, a lower minimum, or a different filter.

The specific controls are useful because they tell the reader what to change.

**Also good**
> No projections yet.

When the create action is already visible, another sentence selling the feature is unnecessary.

## Error messages

Name what failed. Do not repeat the same failure in both the title and the message.

### Before
> **Couldn't load the page**  
> We couldn't load your player data. Check your connection and try again.

### After
> **Couldn't load your player data**  
> Check your connection.

**Prefer**
> Couldn't load your projections.  
> Couldn't save your projection.  
> Couldn't connect to Yahoo.

**Avoid**
> Something went wrong.  
> Oops!  
> HTTP 502 from fantasy-bff.

Mention an external service when it helps the user understand what failed. Do not expose internal implementation details.

Only suggest retrying when retrying could succeed. If an operation definitely did not happen, say so:
> Nothing was charged.  
> Your changes were not saved.

## Loading states

Use a concise present participle and the single ellipsis character.

**Prefer**
> Creating…  
> Syncing…  
> Sending…

For a long or potentially confusing operation, name what is happening:
> Pulling your league settings from Yahoo…

Avoid "Please wait" and unnecessary reassurance.

## Tooltips and help text

Explain something the user cannot reasonably infer from the UI.

### At a setting

Explain the behaviour, including the consequence when useful.

> Goalies projected below this minimum are ranked last.

### At an instance

State the relevant fact and stop.

**Before**
> Projected for fewer games than the league's goalie minimum, so this goalie is ranked last.

**After**
> Projected below the league minimum in games played.

The player is already visible at the bottom of the rankings. Repeating the consequence adds nothing.

### Already right

> Totals divided by the games each player actually dressed for, so someone who missed half the season isn't punished for it.

The explanation is useful because the effect is not obvious from the control itself.

### Needs work

> We use League Size and Roster Slots to optimize the rankings for your league.

Do not invent what a setting does. If the underlying behaviour is unclear, verify it first.

## Banners and notices

Lead with the important fact. Remove information the reader already knows or can infer.

### Before
> **It's the NHL off-season**  
> Team affiliations may be out of date — off-season trades and signings aren't reflected yet. Most rookies aren't in the player list yet. It all updates automatically when the new season opens.

### After
> **Off-season data**  
> Team affiliations lag trades and signings, and most rookies aren't listed yet. This updates when the season opens.

### Consent banner

**Before**
> We use cookies to understand how SlapStat is used, so we can make it better. Decline and we'll still count the visit, but without cookies and without tying it to you.

**After**
> We use cookies to see how SlapStat gets used. Decline and we'll still count the visit, but without cookies and without tying it to you.

**Pattern:** Keep the information that changes what the user understands or can choose. Cut generic reassurance.

## Dialogs and confirmations

The title should name the action or question. The body should carry the consequence, especially for irreversible actions or changes to shared data.

### Already right

> Anyone with this link can see your top 200 players and the scoring settings they were ranked under. Your email is never shown.

> The link updates as your changes are saved.

> Changing this setting will take this projection out of sync with your Yahoo league. If the settings changed in Yahoo, re-sync to pull the latest instead.

**Pattern:** Explain the consequence that is not obvious, then give the relevant alternative when one exists.

Confirmation buttons should name the action:
> Share link  
> Change setting  
> Remove pick

Avoid generic confirmations such as:
> Confirm  
> OK

## Email

Email copy should be brief and task-focused.

### Verification

**Prefer**
> **Subject:** Verify your SlapStat email  
> Please confirm your email address.

> Verify your email

> If you didn't create a SlapStat account, you can safely ignore this email.

### Password reset

**Prefer**
> **Subject:** Reset your SlapStat password  
> We received a request to reset your SlapStat password.

> Choose a new password

> If you didn't request this, you can safely ignore this email.

**Pattern:** Say why the email arrived, provide one obvious action, then say what to do if it was not the user.

## Legal and privacy pages

Legal copy should be plain and concise, but legal meaning comes first.

**Prefer**
> Your password is never stored in plain text.

**Avoid**
> A hash of your password, never the password itself.

**Prefer**
> Account identifier provided by Google or Facebook.

**Avoid**
> Opaque account identifier.

**Pattern:** Remove implementation detail that does not help the reader understand their rights, obligations, or what happens to their data. Do not remove qualifications that matter legally.

Do not invent legal claims, guarantees or rights. When the underlying legal position is unclear, flag it for review instead of guessing.

## Short pairs

These short pairs reinforce the preferred register.

> Before: Every skater and goalie the model reaches, ranked to your own scoring settings.  
> After: Every player ranked to your league's scoring settings.

> Before: The initial stats each player is given.  
> After: The stats players start with.

> Before: Check which players have performed the best over a selected time period, customized to your league settings.  
> After: See which players have performed best over the selected range using your league's scoring settings.

> Before: Your copy of this board lives in your account, so log in or create an account to draft against it. Free to start, and this carries on where you left off.  
> After: Save a copy to your account to keep editing it or use it in Draft Mode.

> Before: Projected for fewer games than the league's goalie minimum, so this goalie is ranked last.  
> After: Projected below the league minimum in games played.
