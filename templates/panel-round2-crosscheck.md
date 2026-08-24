# Panel round 2 - blinded cross-examination

An orchestrator merged two independent reviews of this pull request into a single review.
You are now cross-examining that merged review. **You did not write it, and it is
deliberately unattributed** - you cannot tell which findings came from which reviewer, and
neither can the other cross-examiner. Judge each item on the code alone.

Two failure modes to avoid, in both directions: waving items through because they sound
plausible, and rejecting items to look rigorous. Each verdict costs you the same amount of
evidence.

Work in this order:

1. **Verify before you read the argument.** For each finding, open the cited `file:line` in
   the checked-out repository and form your own view of what that code does. Then read the
   finding's reasoning and decide whether it holds.
2. **Check the dropped list.** The merged review lists findings the orchestrator cut, with
   its reason. Some of those cuts are wrong. Say which should come back.
3. **Look for what the whole panel missed.** You have the diff and the source. If a real
   issue appears nowhere in the merged review, raise it - but hold the same bar you hold the
   existing findings to.

A merged review that survives intact is a fine outcome. So is one you take apart. Say what
the code supports.

## Output schema

Output exactly this structure and nothing else. Keep every entry to one or two sentences.

```
## Verdicts

- id: F1
  verdict: agree | amend | severity-change | disagree
  confidence: high | med | low
  evidence: <file:line plus what you saw there>
  change: <None for agree; the exact amendment or the corrected severity otherwise;
           for disagree, why the finding does not hold>

## Dropped check

- id: D1
  decision: keep-dropped | restore
  evidence: <file:line plus why the cut was right or wrong>

## Missed by the panel

- file:line
  issue: <the problem and why it matters>
  suggested severity: <P0-P4 plus HIGH/LOW>
  suggested fix: <smallest concrete fix>

## Verdict

<one line: is the merged review sound as it stands, does it need minor changes, or does it
need major changes>
```

Verdict meanings:

- `agree` - the finding is real, correctly scoped, and correctly severity-rated.
- `amend` - real, but the description, root cause, or fix is wrong in a way that matters.
- `severity-change` - real, but rated too high or too low. Give the correct `Pn-HIGH/LOW`.
- `disagree` - not a real problem: unreachable state, misread code, or a claim the source
  contradicts. Point at the code that refutes it.

Use `None.` under any heading with no items. Emit a verdict line for **every** `F` id and
every `D` id in the merged review - a missing id is treated as a failed cross-check, not as
agreement.

## Rules

- Ground every verdict in the diff or the checked-out source, with `file:line`. A verdict
  with no evidence is discarded.
- Do not rewrite the review. Verdicts and amendments only.
- Do not invent findings to fill the "Missed by the panel" section. `None.` is a good answer.
- Do not modify files. Do not touch the network or GitHub. Do not delegate to sub-agents.
- English only. No personal paths or machine-specific directories.
