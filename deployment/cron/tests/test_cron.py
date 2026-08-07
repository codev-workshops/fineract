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
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from quartz_to_eventbridge import quartz_to_eventbridge  # noqa: E402


@pytest.mark.parametrize("quartz,expected", [
    # Fineract's seeded expressions (7-field, seconds=0, "1/1" day-of-month, DOW="?").
    ("0 0 22 1/1 * ? *", "cron(0 22 * * ? *)"),
    ("0 1 0 1/1 * ? *", "cron(1 0 * * ? *)"),
    ("0 20 22 1/1 * ? *", "cron(20 22 * * ? *)"),
    # 6-field Quartz (no year) with day-of-month "*" and DOW "?".
    ("0 0 12 * * ?", "cron(0 12 * * ? *)"),
    # Sub-hour increments in the minutes field pass through.
    ("0 0/15 * * * ?", "cron(0/15 * * * ? *)"),
    ("0 0/10 * * * ?", "cron(0/10 * * * ? *)"),
])
def test_seeded_translations(quartz, expected):
    result = quartz_to_eventbridge(quartz)
    assert result.translatable is True
    assert result.schedule_expression() == expected
    assert result.notes == []


def test_day_of_week_passthrough_same_numbering():
    # Quartz and EventBridge share 1-7 = SUN-SAT; a DOW value passes through with
    # day-of-month set to "?".
    result = quartz_to_eventbridge("0 0 9 ? * 2-6 *")
    assert result.translatable is True
    assert result.schedule_expression() == "cron(0 9 ? * 2-6 *)"


def test_named_day_of_week_passthrough():
    result = quartz_to_eventbridge("0 0 18 ? * MON-FRI *")
    assert result.schedule_expression() == "cron(0 18 ? * MON-FRI *)"


def test_constant_nonzero_seconds_flagged_but_translatable():
    result = quartz_to_eventbridge("30 0 12 1/1 * ? *")
    assert result.translatable is True
    assert result.schedule_expression() == "cron(0 12 * * ? *)"
    assert any("second 0" in n for n in result.notes)


def test_sub_minute_seconds_not_representable():
    result = quartz_to_eventbridge("0/30 * * * * ?")
    assert result.translatable is False
    assert result.schedule_expression() is None
    assert any("sub-minute" in n for n in result.notes)


def test_both_dom_and_dow_wildcard_rejected():
    # Not valid Quartz and forbidden by EventBridge.
    result = quartz_to_eventbridge("0 0 12 * * * *")
    assert result.translatable is False


def test_wrong_field_count_rejected():
    result = quartz_to_eventbridge("0 0 12")
    assert result.translatable is False
    assert any("6 or 7" in n for n in result.notes)


def test_empty_expression():
    assert quartz_to_eventbridge("").translatable is False
    assert quartz_to_eventbridge(None).translatable is False
