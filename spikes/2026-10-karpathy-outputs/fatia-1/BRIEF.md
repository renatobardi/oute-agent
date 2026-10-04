# Brief: prompt variants for spike #458 (token measurement, question 7)

You translate a pt-BR agent prompt file of the repo `renatobardi/oute-agent` into English, so we can count tokens of
three variants of the SAME content: (a) today's pt-BR, (b) concise English, (c) English at "80% of ASD-STE100".
The reader of these files is an LLM agent (Claude Code / Codex), not a human. The comparison is only valid if the
content is identical: **do not drop, add, merge away or soften any rule, condition, number, exception or example.**

Do NOT edit any file inside the repo. Write only the output files named in your task (under the scratchpad).

## Keep byte-identical in both variants (this is contract, not prose)
- Everything inside backticks and fenced code blocks: commands, paths, flags, env vars, event names, labels, file names.
  (Inside a fenced block, pt-BR *comments* and pt-BR template text stay as they are.)
- Issue/PR references (`#123`), ADR ids (ADR-07), section numbers (§4.1), versions, dates, numbers, thresholds.
- Literal strings the agent must output or match: `PRONTO #N: …`, `BLOQUEADO #N: …`, `Closes #N`, `Refs #N`,
  `## Falta`, `(ship)`, markers like `<!-- oute-aidlc-qa-pr-audit -->`, and any quoted template the agent must write
  verbatim. Text that the agent writes **for Bardi (the human) in pt-BR** stays pt-BR: translate the instruction around
  it, not the template itself.
- Domain terms that are names: rodada, sessão (as table/event names), dispatcher, worker, pedido (when it is the
  channel object name you may write "request (`pedido`)" once, then "request"), Bardi, herdr, kaizen, AI-DLC phases.
- Markdown structure: same headings (translated), same order, same tables (same rows/columns), same list items, same
  YAML front matter keys (translate the `description:` value; keep `name:`).

## Variant (b) — concise English
Faithful translation, written as tersely as a senior engineer writes for an LLM: imperative mood, no filler, no
politeness, short words. You MAY compress wording (drop redundant connectives, use fragments in lists/tables, symbols
like "→", "=", "≠" where the original already uses that style or where unambiguous). You MAY NOT compress content.

## Variant (c) — English at ~80% of ASD-STE100 (Simplified Technical English)
Same content, written to these limits (the "80%" means: follow the writing rules, but do not enforce the approved-word
dictionary strictly; technical names and the contract items above are always allowed):
- Procedural sentence (an instruction): max 20 words. Descriptive sentence: max 25 words.
- One instruction per sentence. One topic per paragraph, max 6 sentences.
- Active voice in procedures. Imperative for instructions ("Do X."), not "X should be done".
- No progressive -ing verb forms ("is running" → "runs"), no perfect tenses ("has failed" → "failed").
- Noun clusters of max 3 words.
- One word = one meaning: pick one term for each concept and use it everywhere in the file (e.g. always "request",
  never alternate with "proposal"/"job"; always "do not", no contractions).
- Keep articles (the, a). Do not write telegraphic text. Prefer simple approved-style verbs (do, make, use, start,
  stop, read, write, send, examine, make sure) to phrasal or fancy ones.
- Vertical list when a sentence would carry 3+ conditions or items. (You may split a long original bullet or table
  cell into several short sentences; do not restructure tables into prose or the reverse.)
- Safety/irreversible action: command first, then the risk, in the form "CAUTION: <clear command>. <risk>."
  Use this only where the original already warns about a destructive/irreversible action.
If a limit conflicts with fidelity (a contract string is long), fidelity wins.

## Procedure
1. Read the whole source file first.
2. Write the variant file(s) to the exact output path(s) given in your task (create parent dirs).
   Work section by section for large files; append as you go so nothing is lost. Do not summarize.
3. Self-check before finishing, and fix what fails:
   - same number of markdown headings and table rows as the source (`grep -c '^#'`, `grep -c '^|'`);
   - the multiset of `#<number>` references is identical to the source:
     `diff <(grep -o '#[0-9]\+' SRC | sort) <(grep -o '#[0-9]\+' OUT | sort)`;
   - the set of backticked spans is identical to the source, except spans that were pt-BR prose in backticks:
     `diff <(grep -o '`[^`]*`' SRC | sort -u) <(grep -o '`[^`]*`' OUT | sort -u)` — explain each remaining diff line;
   - no pt-BR prose left outside the contract items (`grep -n '[áéíóúâêôãõç]' OUT` and justify what remains).
4. Final answer (short): output paths; the results of the 4 checks; a list of every place where you were unsure how
   to translate without changing meaning (line + what you chose); anything in the source that is ambiguous in pt-BR.
