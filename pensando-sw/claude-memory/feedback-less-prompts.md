---
name: feedback-less-prompts
description: User dislikes excessive yes/no prompts and clarification questions during testbed operations — infer from context instead
type: feedback
originSessionId: 7cf85133-b26e-47cd-902a-cfcdeeb43366
---
Do not ask clarification questions when context is available to infer the answer.

**Why:** User found the image-load workflow too interactive — too many AskUserQuestion prompts for pipeline, build tag, profile, and confirmation at each step. This slows down operations and requires unnecessary intervention.

**How to apply:**
- Infer pipeline from the current git branch (e.g., `unify-path-reactivation-rx-hysteresis` is a hydra branch → hydra pipeline)
- Infer build tag from the FW version already on the NIC (`nicctl show version firmware`)
- When the user states what they want (e.g., "load default profile"), just do it — don't ask for confirmation
- Present the plan once if needed, then execute without step-by-step confirmation
- Only ask when genuinely ambiguous (e.g., multiple ASICs possible, no way to infer)
- Batch operations and minimize round-trips with the user
