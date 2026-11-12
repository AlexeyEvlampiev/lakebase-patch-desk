import re
from pathlib import Path

import messages

SQL = Path(__file__).resolve().parents[2] / "db" / "core" / "patch.sql"


def codes_in_sql() -> set[str]:
    return set(re.findall(r"THEN '(core\.patch(?:_line)?\.[a-z_]+)'", SQL.read_text()))


def test_every_code_in_the_sql_has_a_message():
    codes = codes_in_sql()
    assert len(codes) >= 10  # the pattern still finds the codes
    assert codes - messages.PROBLEMS.keys() == set()


def test_no_message_for_a_code_the_sql_does_not_return():
    assert messages.PROBLEMS.keys() - codes_in_sql() == set()


def test_unknown_and_empty():
    assert messages.problem_message(None) == ""
    assert messages.problem_message("core.patch.new_code") == "core.patch.new_code"
