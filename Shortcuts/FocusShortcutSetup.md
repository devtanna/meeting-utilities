# Set up “Meeting Utility: Focus until end”

Meeting Utility never changes Focus by itself. After it opens a meeting link (and only if you turned on
**Settings › Focus › Turn on Do Not Disturb when I join**), it runs this one Shortcut with a tiny JSON input:

```json
{"version":1,"requestID":"…","deadline":"2026-11-05T10:30:00Z","deadlineEpoch":1793874600,"minutesUntilDeadline":30}
```

The Shortcut keeps any Focus that is already on. Otherwise it turns on Do Not Disturb **until the meeting's
scheduled end**, and macOS turns it off by itself. Meeting Utility never sends “Focus off”.

## Build it once (about 2 minutes)

Open **Shortcuts** › **File › New Shortcut** and name it exactly `Meeting Utility: Focus until end`.
Add these actions in order:

1. **Get Dictionary from Input** — input: *Shortcut Input*.
2. **Get Dictionary Value** — get *Value* for key `minutesUntilDeadline` in *Dictionary*. Rename the result “Minutes” (optional).
3. **If** *Dictionary Value* **is greater than** `0`
   1. **If** *Dictionary Value* **is less than** `721` *(12-hour safety limit)*
      1. **Get Current Focus**.
      2. **If** *Current Focus* **has any value**
         1. **Text** `{"status":"preserved_existing"}`
         2. **Stop and Output** *Text*.
      3. **Otherwise**
         1. **Adjust Date** — *Add* *Dictionary Value* *minutes* to *Current Date*.
         2. **Set Focus** — turn *Do Not Disturb* **On** **Until Time** → *Adjusted Date*.
         3. **Text** `{"status":"enabled_until"}`
         4. **Stop and Output** *Text*.
      4. **End If**
   2. **End If**
4. **End If**
5. **Text** `{"status":"failed"}` and **Stop and Output** *Text* (reached only for invalid input).

In the Shortcut's details (ⓘ), allow it to **Receive** *Text* and *Files* input (the app passes a JSON file).

## Test it

In Meeting Utility: **Settings › Focus › 2. Choose and test it**, pick the Shortcut and press **Test Shortcut**.
The test asks for a 1-minute Do Not Disturb. Expected outcomes:

| Situation before the test | Expected result |
|---|---|
| No Focus on | “Worked: Do Not Disturb is on for 1 minute.” DND turns itself off ~1 minute later. |
| Any Focus already on (Work, Sleep, DND…) | “Worked: a Focus was already on and was kept.” Nothing changes. |
| Shortcut deleted / errors | “Failed … Focus was left unchanged.” |

If **Get Current Focus** itself fails, the Shortcut stops with an error; Meeting Utility treats that as a failure
and makes no change, so “no Focus” is never confused with a failed query.

## Command line (for verification)

```sh
shortcuts list --show-identifiers | grep "Meeting Utility"
echo '{"version":1,"requestID":"test","minutesUntilDeadline":1}' > /tmp/mu.json
shortcuts run "Meeting Utility: Focus until end" --input-path /tmp/mu.json --output-path /tmp/mu.out --output-type public.plain-text; cat /tmp/mu.out
```
