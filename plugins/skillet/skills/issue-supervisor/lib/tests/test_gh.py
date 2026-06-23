from supervisorlib import gh


def test_eligible_issues_filters_label_epic_and_ownership():
    issues = [
        {"number": 1, "labels": [{"name": "auto"}]},
        {"number": 2, "labels": [{"name": "auto"}, {"name": "epic"}]},   # epic excluded
        {"number": 3, "labels": [{"name": "bug"}]},                      # no auto
        {"number": 4, "labels": [{"name": "auto"}]},                     # owned, excluded
    ]
    result = gh.eligible_issues(issues, owned_issue_numbers=[4])
    assert [i["number"] for i in result] == [1]


def test_eligible_issues_sorted_lowest_first():
    issues = [
        {"number": 9, "labels": [{"name": "auto"}]},
        {"number": 3, "labels": [{"name": "auto"}]},
    ]
    assert [i["number"] for i in gh.eligible_issues(issues, owned_issue_numbers=[])] == [3, 9]


def test_open_pr_branches_set():
    prs = [{"headRefName": "auto-1-x"}, {"headRefName": "auto-2-y"}]
    assert gh.open_pr_branches(prs) == {"auto-1-x", "auto-2-y"}
