import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from terraform_deploy import classify_error, deadline_exceeded


def test_capacity_error_is_retryable():
    assert classify_error(["Error: 500-InternalError, Out of host capacity."], "") == "capacity"


def test_limit_error_is_not_retryable_even_with_capacity_words():
    assert classify_error(["LimitExceeded: no capacity in your service limits"], "") == "limit"
    assert classify_error([], "vcn-count limit exceeded") == "limit"


def test_unknown_error_is_other():
    assert classify_error(["400-InvalidParameter, boot volume size"], "") == "other"
    assert classify_error([], None) == "other"


def test_deadline():
    assert not deadline_exceeded(0, 3600 * 23.9, 24)
    assert deadline_exceeded(0, 3600 * 24.1, 24)
    assert deadline_exceeded(100, 100 + 3601, 1)
