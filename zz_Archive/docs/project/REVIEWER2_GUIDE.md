# Reviewer 2 guide: held-aside contact-state labels (rebounding Step 02)

How to fill `outputs/rebounding/step02/review/reviewer2_heldout.csv` from the pages
`outputs/rebounding/step02/review/heldout_01.png` … `heldout_15.png`. The column definitions follow
[`ANNOTATION_RUBRIC.md`](ANNOTATION_RUBRIC.md) (rubric v1); this guide explains how to read the pages.

**Two rules before you start:**
- Don't open `reviewer1_heldout.csv` or the automated labels, and don't ask anyone who has seen them to read a
  held-aside item for you. Your labels only count as a check if they're independent.
- Edit the file in a text editor, or in Excel saved back as CSV. Don't change the column names. Leave `item`,
  `episode_id` and `game_id` as they are.

Each sheet row matches one item: row 1 is the top half of `heldout_01.png`, row 2 its bottom half, and so on.

---

## Part 1: How to read a page

Each PNG holds **2 shots**, one per row. Each row has a timeline (left) and a top-down view (right).

### Left panel: timeline

| What you see | Meaning |
| --- | --- |
| **x-axis** | Frames from release. 25 frames = 1 second. A faint gridline marks every frame, and every 5th frame is labelled. **Write frames exactly as this axis shows them.** |
| **Black line** | Ball height (ft) |
| **Black dots on it** | Frames where the ball was actually measured. Stretches without dots are filled in. |
| **Grey dashed line** | Ball's horizontal distance to the hoop (ft) |
| **5 coloured lines** | Ball's horizontal distance to each of the 5 players who get closest. Each is labelled once at its lowest point, e.g. `D9138` = defender, id ending 9138; `O5222` = offence. |
| **Orange dotted line** | 10 ft, rim height |
| **Grey dotted line** | 3 ft, close enough to touch the ball |
| **Tan dotted line** | 2.2 ft, near the floor |
| **Blue dashed vertical line** | `endFrame`: the data's mark for when the shot reaches the rim area. It's a hint, not the answer. |

### Right panel: top-down view

- The ball's path runs from 12 frames before `endFrame`, grey (early) to black (late).
- Player paths: **red = offence, blue = defence**. The dot with a label is where each player ends.
- The orange circle is the hoop. The outer rectangle is the court boundary.
- Use this panel to check **out of bounds** (ball dots past the court lines) and **who is near whom**.

### Patterns to look for

| Event | What it looks like |
| --- | --- |
| **Rim/board hit** | The black line suddenly **bends** (often bounces back up) while the grey dashed line is low (about 3 ft or less) and the ball is near or above 10 ft |
| **Ball sitting on the rim** | The black line stays **flat around 10–11 ft** for several frames, with the grey dashed line low |
| **Floor bounce** | The black line makes a **V** at about 1.5–2.5 ft |
| **Player touch** | The black line bends or suddenly slows **at the same moment** a coloured line is under the 3 ft line |
| **Catch / control** | The black line **stops falling** and stays steady (usually 3–7 ft), while **one** coloured line stays low (about 2.5 ft or less) for 6+ frames |
| **Tip** | A bend near a player, then the ball keeps flying and that player's coloured line goes **up** |
| **Free fall (nobody touching it)** | The black line curves down **faster and faster**. If it suddenly falls more slowly than that, someone touched it. |

A smooth stretch of black line with no dots is filled in, not measured. Don't place a contact frame inside such a
stretch unless the change of course is obvious on both sides of it.

---

## Part 2: What goes in each column

Frames are always **numbers from the x-axis** (e.g. `33`).

### 1. `first_rim_or_board_rel`
- **What:** the frame the ball first hits the rim or backboard.
- **How:** find the first bend near the hoop, and write the **last frame before** the line changes direction.
- **Values:** a number, `none` (airball, or blocked before reaching the rim) or `UNKNOWN` (you can't place it within
  ±2 frames).

### 2. `contact_kind`
- **Values:** `rim`, `board`, `rim_or_board`, `none` or `UNKNOWN`.
- `board`: the ball is clearly above the rim when it changes course and comes back out.
- `rim`: the change happens right at about 10–11 ft, close to the hoop.
- Not sure which? Write `rim_or_board`. This is normal; the tracking struggles here.
- It must match column 1: if column 1 is `none`, this is `none`.

### 3. `first_player_contact_rel`
- **What:** the first frame a player touches the ball, after the rim hit (or before it, for a block).
- **How:** a bend or sudden slowing of the black line **at the same moment** a coloured line is under 3 ft.
- **Values:** a number, `none` (nobody touches it before it goes out or the window ends) or `UNKNOWN`.
- **Don't** count a player just because they're close. The black line must change.

### 4. `first_contact_player_id`
- **What:** who made that first touch.
- **Format:** exactly the page label, e.g. `D9138` or `O5222`.
- **Write `UNKNOWN` if** two coloured lines are within about 1 ft of each other at that frame (a crowd), or no player
  is labelled.

### 5. `first_contact_type`

| Value | When |
| --- | --- |
| `catch` | The same player holds the ball within about 8 frames of the touch |
| `tip` | The ball flies on after the touch |
| `block` | A touch before the rim hit |
| `none` | Column 3 is `none` |
| `UNKNOWN` | You can't tell |

### 6. `tips_rel`
- **What:** every touch before control that **wasn't** the catch.
- **Format:** `frame:player`, separated by `;`, e.g. `48:D9092;56:O9100`.
- Use `?` for a player you can't name, e.g. `18:?`.
- No tips? **Leave it empty.**
- If the first touch was a tip, it goes here too.

### 7. `first_control_rel`
- **What:** the first frame someone clearly **has** the ball.
- **How:** the frame where the black line **stops falling** and one coloured line stays low for 6+ frames. A dribble
  right after still counts as control.
- **Values:** a number, `none` (out of bounds, or the window ends first) or `UNKNOWN`.

### 8. `controller_id`
- **What:** who has it. Use the page label, e.g. `D9295`.
- `UNKNOWN` if two players **share** it (a tie-up, both lines very low).
- **Leave it empty** if column 7 is `none`.
- This is not the 1 ft crowd rule: name whoever is holding it.

### 9. `terminal`

| Value | When |
| --- | --- |
| `control` | Someone has it |
| `held_ball` | Two players tied up |
| `out_of_bounds` | Ball dots leave the court in the right panel |
| `unresolved` | The window ends with the ball still loose |

### 10. `label_confidence`

| Value | When |
| --- | --- |
| `high` | Every field is clear and within the frame tolerance |
| `medium` | One field is uncertain |
| `low` | The sequence is a best guess |

### 11. `note`
Free text, short. Example: "crowd under rim; D and O within 1 ft at catch". **Avoid commas**, or put the whole note
in quotes.

---

## Part 3: A made-up filled row (not from the held-aside set)

```
first_rim_or_board_rel   = 31
contact_kind             = rim
first_player_contact_rel = 58
first_contact_player_id  = D1234
first_contact_type       = tip
tips_rel                 = 58:D1234
first_control_rel        = 70
controller_id            = O5678
terminal                 = control
label_confidence         = medium
note                     = ball sits on ring 31-38; bounce at 66
```

## Part 4: Speed tips

- Do a rough first pass on all 30 rows (about 45 minutes), then a second pass only on the rows marked `low`.
- Don't agonise. Writing `UNKNOWN` is a valid answer and costs nothing.
- When all 30 rows are filled, rescore with `run_step02.R --phase=score`, then `--phase=gate` (about 2 minutes).
