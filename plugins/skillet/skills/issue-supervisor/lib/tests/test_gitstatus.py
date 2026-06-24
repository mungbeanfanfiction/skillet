from supervisorlib import gitstatus


def test_classify_porcelain_clean():
    assert gitstatus.classify_porcelain("") == "clean"


def test_classify_porcelain_uncommitted():
    assert gitstatus.classify_porcelain(" M file.py\n") == "uncommitted"


def test_classify_porcelain_untracked_only():
    assert gitstatus.classify_porcelain("?? new.py\n") == "uncommitted"


def test_ahead_count_parses_rev_list_output():
    assert gitstatus.ahead_count("3") == 3
    assert gitstatus.ahead_count("0") == 0
    assert gitstatus.ahead_count("") == 0
    assert gitstatus.ahead_count("not-a-number") == 0
