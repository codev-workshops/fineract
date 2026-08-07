#!/usr/bin/env python3
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements. See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership. The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License. You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied. See the License for the
# specific language governing permissions and limitations
# under the License.
#
"""Translate Fineract's stored Quartz cron expressions into AWS EventBridge
Scheduler cron expressions.

Quartz cron ::= seconds minutes hours day-of-month month day-of-week [year]
                (6 or 7 fields; a leading seconds field)

EventBridge  ::= cron(minutes hours day-of-month month day-of-week year)
                (6 fields, wrapped in cron(...); no seconds field; year required)

Documented differences that this translator handles:

  * Seconds field. EventBridge has none. Quartz's seconds field is dropped.
    - "0" (fire on the minute boundary): translated 1:1.
    - a constant like "30": adapted to fire at second 0 of the minute; flagged.
    - an increment/range like "0/30" (sub-minute cadence): NOT representable in
      EventBridge (1 minute is the finest granularity); flagged as not 1:1.

  * Year field. Quartz's optional 7th field maps to EventBridge's required 6th
    field. When Quartz omits it, "*" is supplied.

  * Day-of-week numbering. Both Quartz and EventBridge use 1-7 = SUN-SAT
    (1 = Sunday), so numeric and SUN-SAT names pass through unchanged. (This is
    NOT the Unix 0-6 convention.)

  * The "?" rule. Both dialects require exactly one of day-of-month / day-of-week
    to be "?" and forbid "*" in both at once. Valid Quartz already satisfies this,
    so "?" passes through. Expressions that violate the rule are flagged.

  * "1/1" in day-of-month (Fineract's idiom for "every day") is normalised to
    "*", which EventBridge accepts and which reads more clearly.

Anything the translator cannot represent 1:1 is returned with translatable=False
and a human-readable note, rather than silently producing a wrong schedule.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from typing import List, Optional


@dataclass
class TranslationResult:
    quartz: str
    eventbridge: Optional[str]
    translatable: bool
    notes: List[str] = field(default_factory=list)

    def schedule_expression(self) -> Optional[str]:
        """The value for an EventBridge Scheduler ``schedule_expression`` (already
        wrapped in ``cron(...)``)."""
        return f"cron({self.eventbridge})" if self.eventbridge else None


def _is_zero_seconds(seconds: str) -> bool:
    return seconds in ("0", "00")


def _seconds_note(seconds: str) -> Optional[str]:
    if _is_zero_seconds(seconds):
        return None
    # Sub-minute cadence cannot be represented at all.
    if any(c in seconds for c in ("/", "-", ",")) or seconds == "*":
        return (f"Quartz seconds field '{seconds}' implies sub-minute cadence; "
                "EventBridge's finest granularity is 1 minute, so this cannot be represented 1:1.")
    # A constant non-zero second simply shifts the fire second, which EventBridge ignores.
    return (f"Quartz seconds field '{seconds}' dropped; EventBridge fires on the minute boundary "
            "(second 0) instead of second {seconds}.".format(seconds=seconds))


def _normalise_dom(dom: str) -> str:
    # Fineract seeds "1/1" (every day, starting day 1) which is semantically "*".
    if dom in ("1/1", "*/1"):
        return "*"
    return dom


_FIELD_TOKEN = re.compile(r"^[0-9A-Za-z\*\?\-,/#LW]+$")


def quartz_to_eventbridge(expr: str) -> TranslationResult:
    """Translate a single Quartz cron expression to an EventBridge one."""
    if expr is None or not expr.strip():
        return TranslationResult(quartz=expr, eventbridge=None, translatable=False,
                                 notes=["empty expression"])

    tokens = expr.split()
    if len(tokens) not in (6, 7):
        return TranslationResult(
            quartz=expr, eventbridge=None, translatable=False,
            notes=[f"expected 6 or 7 Quartz fields, got {len(tokens)}"])

    for t in tokens:
        if not _FIELD_TOKEN.match(t):
            return TranslationResult(
                quartz=expr, eventbridge=None, translatable=False,
                notes=[f"unrecognised token '{t}'"])

    seconds = tokens[0]
    minutes, hours, dom, month, dow = tokens[1], tokens[2], tokens[3], tokens[4], tokens[5]
    year = tokens[6] if len(tokens) == 7 else "*"

    notes: List[str] = []
    translatable = True

    sec_note = _seconds_note(seconds)
    if sec_note:
        notes.append(sec_note)
        if not _is_zero_seconds(seconds) and any(c in seconds for c in ("/", "-", ",", "*")):
            translatable = False

    dom = _normalise_dom(dom)

    # Enforce the exactly-one-"?" rule that both dialects share.
    dom_q = dom == "?"
    dow_q = dow == "?"
    if dom_q == dow_q:
        # Either both "?" or neither "?" -> not a valid Quartz/EventBridge pairing.
        if dom == "*" and dow == "*":
            notes.append("day-of-month and day-of-week are both '*'; EventBridge forbids this. "
                         "Set one to '?'.")
        elif not dom_q and not dow_q:
            notes.append("neither day-of-month nor day-of-week is '?'; EventBridge requires "
                         "exactly one to be '?'.")
        else:
            notes.append("both day-of-month and day-of-week are '?'; EventBridge requires "
                         "exactly one to be a value or '*'.")
        translatable = False

    eventbridge = " ".join([minutes, hours, dom, month, dow, year])

    return TranslationResult(quartz=expr, eventbridge=eventbridge if translatable else None,
                             translatable=translatable, notes=notes)


# ---------------------------------------------------------------------------
# Reading Fineract's seeded jobs straight from the Liquibase changelog, so the
# default mapping can be produced without a running database.
# ---------------------------------------------------------------------------

def read_seeded_jobs(liquibase_xml: str) -> List[dict]:
    """Parse (job name, cron expression) pairs out of the seeded job_config rows."""
    import xml.etree.ElementTree as ET

    tree = ET.parse(liquibase_xml)
    root = tree.getroot()

    # Namespaces vary across Liquibase versions; match on the local tag name.
    def local(tag: str) -> str:
        return tag.rsplit("}", 1)[-1]

    jobs: List[dict] = []
    for insert in root.iter():
        if local(insert.tag) != "insert":
            continue
        if insert.get("tableName") != "job":
            continue
        cols = {}
        for col in insert:
            if local(col.tag) != "column":
                continue
            cols[col.get("name")] = col.get("value")
        if "cron_expression" in cols:
            jobs.append({
                "name": cols.get("display_name") or cols.get("name"),
                "cron": cols.get("cron_expression"),
                "node_id": cols.get("node_id"),
            })
    return jobs


def translate_jobs(jobs: List[dict], timezone: str) -> List[dict]:
    out = []
    for job in jobs:
        result = quartz_to_eventbridge(job["cron"])
        out.append({
            "name": job.get("name"),
            "node_id": job.get("node_id"),
            "timezone": timezone,
            "quartz": job["cron"],
            "schedule_expression": result.schedule_expression(),
            "translatable": result.translatable,
            "notes": result.notes,
        })
    return out


def render_markdown(rows: List[dict], timezone: str) -> str:
    lines = [
        f"# Quartz -> EventBridge Scheduler cron mapping",
        "",
        f"Tenant timezone applied to every schedule: `{timezone}` "
        "(EventBridge Scheduler `ScheduleExpressionTimezone`).",
        "",
        "| job | Quartz cron | EventBridge schedule_expression | 1:1 | notes |",
        "| --- | --- | --- | --- | --- |",
    ]
    for r in rows:
        note = "; ".join(r["notes"]) if r["notes"] else ""
        expr = r["schedule_expression"] or "(not representable)"
        lines.append(
            f"| {r['name']} | `{r['quartz']}` | `{expr}` | {'yes' if r['translatable'] else 'NO'} | {note} |")
    lines.append("")
    return "\n".join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    src = parser.add_mutually_exclusive_group()
    src.add_argument("--liquibase", metavar="XML",
                     help="path to the seeded 0002_initial_data.xml (job rows)")
    src.add_argument("--jobs-json", metavar="FILE",
                     help="JSON list of {name, cron[, node_id]} objects to translate")
    src.add_argument("--expr", metavar="QUARTZ",
                     help="translate a single Quartz expression and exit")
    parser.add_argument("--timezone", default="Asia/Kolkata",
                        help="tenant timezoneId to attach to every schedule (default: Asia/Kolkata)")
    parser.add_argument("--format", choices=("markdown", "json"), default="markdown")
    args = parser.parse_args(argv)

    if args.expr:
        result = quartz_to_eventbridge(args.expr)
        print(json.dumps({
            "quartz": result.quartz,
            "schedule_expression": result.schedule_expression(),
            "translatable": result.translatable,
            "notes": result.notes,
        }, indent=2))
        return 0 if result.translatable else 1

    if args.jobs_json:
        with open(args.jobs_json) as fh:
            jobs = json.load(fh)
    elif args.liquibase:
        jobs = read_seeded_jobs(args.liquibase)
    else:
        parser.error("one of --liquibase, --jobs-json or --expr is required")
        return 2

    rows = translate_jobs(jobs, args.timezone)
    if args.format == "json":
        print(json.dumps(rows, indent=2))
    else:
        print(render_markdown(rows, args.timezone))
    return 0 if all(r["translatable"] for r in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
