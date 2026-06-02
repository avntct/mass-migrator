# 6-Frame Storyboard: Andy's Migration Crisis

A visual narrative showing a DBA Lead's journey from weekend migration anxiety to calm Monday mornings.

---

## Frame 1: Introducing the Main Character
**Andy, 40, DBA Lead**

Andy manages database operations for a large enterprise. Terabytes of critical data must be migrated every weekend within a strict 4-hour maintenance window. He's experienced, methodical—but increasingly anxious about the growing data volumes.

**Visual:** Andy at a workstation with multiple monitors showing database dashboards, server racks in the background. A calendar on the wall highlights "Saturday 2am - 6am: Migration Window."

---

## Frame 2: The Problem Emerges
**Migrations running dangerously slow**

Each weekend, Andy watches his migration scripts crawl through the data. What used to finish in 3 hours now takes 3.5 hours. The data keeps growing, but the 4-hour window doesn't. He's running out of margin.

**Visual:** Progress bar at 68% with clock showing 5:15am. Terminal window showing sequential batch processing. Andy leaning forward, checking his watch. Red warning indicator: "ETA: 6:22am — EXCEEDS WINDOW."

---

## Frame 3: The "Oh Crap" Moment
**Monday morning disaster**

The migration didn't finish. Andy's phone explodes at 7am—users can't access the system. The VP of Operations is in the CTO's office. Production is down. Hundreds of employees are blocked. Andy's weekend scripts have become a company-wide crisis.

**Visual:** Split screen—left side shows a failed migration log with error state, database icon with red X. Right side shows Slack/email notifications flooding in: "System down?" "Can't login" "URGENT." Andy on phone, hand on forehead.

---

## Frame 4: The Solution Appears
**Vendor demo: parallel migration tooling**

During a routine tooling review, Andy sees a demo of a migration tool with parallel batch processing, checkpoint recovery, and real-time progress tracking. He's skeptical—he's seen "10x faster" claims before. But the architecture diagram shows exactly where his bottleneck is.

**Visual:** Presentation screen showing architecture diagram: single-threaded pipeline (crossed out) vs. parallel partitioned processing (highlighted). Demo dashboard showing concurrent worker threads. Andy in the audience, arms crossed but leaning in.

---

## Frame 5: The "Aha" Moment
**10x faster—seeing is believing**

Andy runs a pilot migration on a test dataset. His old scripts: 3.5 hours. The new tool with parallel batch processing: 22 minutes. He watches the dashboard as multiple workers chew through partitions simultaneously. The progress bar moves faster than he's ever seen.

**Visual:** Dashboard showing 8 parallel workers processing data partitions, each with its own progress indicator. Aggregated progress bar at 94%. Clock showing 2:45am—well within the window. Terminal output showing "Partition 7/8 complete. ETA: 2:51am."

---

## Frame 6: Life After the Solution
**Monday mornings are calm**

Weekend migrations now finish in under 90 minutes. Andy sleeps through Saturday night. Monday mornings, the system is ready before anyone arrives. The VP who was furious now praises Andy for "modernizing our data infrastructure." He's no longer the bottleneck—he's the hero who fixed it.

**Visual:** Clean dashboard showing "Migration Complete: 1h 23m" with green checkmarks. Andy at his desk Monday morning, coffee in hand, relaxed posture. Slack message from VP: "Great work on the pipeline improvements." Server rack icons all showing healthy green status.

---

## Visual Style Notes

**Wireframe-style with server/database iconography:**
- Monochrome or limited color palette (grays, with red for alerts, green for success)
- Database cylinder icons, server rack illustrations, terminal windows
- Clean lines, technical diagram aesthetic
- Progress bars, dashboards, and monitoring UIs as key visual elements
- Character rendered simply—focus on the technology context

---

## Storyboard Test Checklist

| Question | Assessment |
|----------|------------|
| Is Andy relatable? | Yes — Any DBA with batch windows will recognize this |
| Is the problem visceral? | Yes — "Running out of margin" creates tension |
| Is the "Oh Crap" moment real? | Yes — Production down = career-defining crisis |
| Is the solution introduction natural? | Yes — Vendor demos are standard in enterprise |
| Is the "Aha" moment believable? | Yes — 10x improvement with visible parallel processing |
| Is the "after" state aspirational? | Yes — From crisis manager to recognized innovator |

---

*Generated using the /storyboard skill*
