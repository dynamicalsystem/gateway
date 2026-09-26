from types import SimpleNamespace
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))
from oci_inventory import classify, is_free_tier

FREE = {"orcl-cloud": {"free-tier-retained": "true"}}


def inst(name, managed=True):
    return SimpleNamespace(display_name=name, freeform_tags={"managed-by": "terraform"} if managed else {})


def vol(name, vid, size=50, free=True):
    return SimpleNamespace(display_name=name, id=vid, size_in_gbs=size, system_tags=FREE if free else {})


def test_clean_tenancy_has_no_problems():
    problems, notes, total = classify([inst("a")], [vol("a-boot", "v1")], [], {"v1": "i1"}, {})
    assert problems == [] and notes == [] and total == 50


def test_unattached_volume_is_a_problem():
    problems, _, _ = classify([], [vol("orphan", "v1")], [], {}, {})
    assert problems == ["boot volume orphan (50 GB) is not attached"]


def test_untagged_instance_is_a_problem():
    problems, _, _ = classify([inst("x", managed=False)], [], [], {}, {})
    assert problems == ["instance x has no managed-by tag"]


def test_missing_free_tier_marker_inside_allowance_is_a_problem():
    problems, _, _ = classify([], [vol("stuck", "v1", free=False)], [], {"v1": "i1"}, {})
    assert len(problems) == 1 and "free-tier-retained" in problems[0] and "support request" in problems[0]


def test_missing_marker_over_allowance_is_only_a_note():
    vols = [vol(f"v{n}", f"v{n}", size=50, free=False) for n in range(5)]
    problems, notes, total = classify([], vols, [], {f"v{n}": "i" for n in range(5)}, {})
    assert total == 250
    assert problems == ["total volume storage 250 GB exceeds the 200 GB allowance"]
    assert len(notes) == 5


def test_block_volumes_count_toward_total_and_attachment():
    problems, _, total = classify([], [vol("b", "v1")], [vol("data", "v2", size=100)], {"v1": "i"}, {})
    assert total == 150
    assert problems == ["block volume data (100 GB) is not attached"]


def test_is_free_tier_reads_system_tag():
    assert is_free_tier(vol("a", "v", free=True))
    assert not is_free_tier(vol("a", "v", free=False))
    assert not is_free_tier(SimpleNamespace(system_tags=None))
