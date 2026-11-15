// Responses recorded live on 2026-11-04 from api.github.com/graphql with the query PullRequestQuery builds.
enum Recorded {
    /// cli/cli, branches: draft PR with a failing check, merged PR, fork PR (closed), no PR.
    static let cliCLI = """
        {
          "data": {
            "repository": {
              "b0": {
                "nodes": [
                  {
                    "number": 14927,
                    "url": "https://github.com/cli/cli/pull/14927",
                    "state": "OPEN",
                    "isDraft": true,
                    "reviewDecision": "REVIEW_REQUIRED",
                    "mergedAt": null,
                    "isCrossRepository": false,
                    "commits": {
                      "nodes": [
                        {"commit":{"statusCheckRollup":{"state":"FAILURE","contexts":{"totalCount":25,"checkRunCountsByState":[{"state":"ACTION_REQUIRED","count":0},{"state":"CANCELLED","count":0},{"state":"COMPLETED","count":0},{"state":"FAILURE","count":1},{"state":"IN_PROGRESS","count":0},{"state":"NEUTRAL","count":0},{"state":"PENDING","count":0},{"state":"QUEUED","count":0},{"state":"SKIPPED","count":13},{"state":"STALE","count":0},{"state":"STARTUP_FAILURE","count":0},{"state":"SUCCESS","count":11},{"state":"TIMED_OUT","count":0},{"state":"WAITING","count":0}],"statusContextCountsByState":[{"state":"EXPECTED","count":0},{"state":"ERROR","count":0},{"state":"FAILURE","count":0},{"state":"PENDING","count":0},{"state":"SUCCESS","count":0}]}}}}
                      ]
                    }
                  }
                ]
              },
              "b1": {
                "nodes": [
                  {
                    "number": 14918,
                    "url": "https://github.com/cli/cli/pull/14918",
                    "state": "MERGED",
                    "isDraft": false,
                    "reviewDecision": "APPROVED",
                    "mergedAt": "2026-11-03T17:40:14Z",
                    "isCrossRepository": false,
                    "commits": {
                      "nodes": [
                        {"commit":{"statusCheckRollup":{"state":"SUCCESS","contexts":{"totalCount":18,"checkRunCountsByState":[{"state":"ACTION_REQUIRED","count":0},{"state":"CANCELLED","count":0},{"state":"COMPLETED","count":0},{"state":"FAILURE","count":0},{"state":"IN_PROGRESS","count":0},{"state":"NEUTRAL","count":0},{"state":"PENDING","count":0},{"state":"QUEUED","count":0},{"state":"SKIPPED","count":6},{"state":"STALE","count":0},{"state":"STARTUP_FAILURE","count":0},{"state":"SUCCESS","count":12},{"state":"TIMED_OUT","count":0},{"state":"WAITING","count":0}],"statusContextCountsByState":[{"state":"EXPECTED","count":0},{"state":"ERROR","count":0},{"state":"FAILURE","count":0},{"state":"PENDING","count":0},{"state":"SUCCESS","count":0}]}}}}
                      ]
                    }
                  }
                ]
              },
              "b2": {
                "nodes": [
                  {
                    "number": 14908,
                    "url": "https://github.com/cli/cli/pull/14908",
                    "state": "CLOSED",
                    "isDraft": false,
                    "reviewDecision": "REVIEW_REQUIRED",
                    "mergedAt": null,
                    "isCrossRepository": true,
                    "commits": {
                      "nodes": [
                        {"commit":{"statusCheckRollup":{"state":"SUCCESS","contexts":{"totalCount":7,"checkRunCountsByState":[{"state":"ACTION_REQUIRED","count":0},{"state":"CANCELLED","count":0},{"state":"COMPLETED","count":0},{"state":"FAILURE","count":0},{"state":"IN_PROGRESS","count":0},{"state":"NEUTRAL","count":0},{"state":"PENDING","count":0},{"state":"QUEUED","count":0},{"state":"SKIPPED","count":5},{"state":"STALE","count":0},{"state":"STARTUP_FAILURE","count":0},{"state":"SUCCESS","count":2},{"state":"TIMED_OUT","count":0},{"state":"WAITING","count":0}],"statusContextCountsByState":[{"state":"EXPECTED","count":0},{"state":"ERROR","count":0},{"state":"FAILURE","count":0},{"state":"PENDING","count":0},{"state":"SUCCESS","count":0}]}}}}
                      ]
                    }
                  }
                ]
              },
              "b3": {
                "nodes": []
              }
            }
          }
        }
        """

    /// rails/rails, three fork PRs mixing check runs and commit statuses, one pending, and no PR.
    static let railsRails = """
        {
          "data": {
            "repository": {
              "b0": {
                "nodes": [
                  {
                    "number": 59589,
                    "url": "https://github.com/rails/rails/pull/59589",
                    "state": "OPEN",
                    "isDraft": false,
                    "reviewDecision": null,
                    "mergedAt": null,
                    "isCrossRepository": true,
                    "commits": {
                      "nodes": [
                        {"commit":{"statusCheckRollup":{"state":"PENDING","contexts":{"totalCount":4,"checkRunCountsByState":[{"state":"ACTION_REQUIRED","count":0},{"state":"CANCELLED","count":0},{"state":"COMPLETED","count":0},{"state":"FAILURE","count":0},{"state":"IN_PROGRESS","count":1},{"state":"NEUTRAL","count":0},{"state":"PENDING","count":0},{"state":"QUEUED","count":0},{"state":"SKIPPED","count":0},{"state":"STALE","count":0},{"state":"STARTUP_FAILURE","count":0},{"state":"SUCCESS","count":1},{"state":"TIMED_OUT","count":0},{"state":"WAITING","count":0}],"statusContextCountsByState":[{"state":"EXPECTED","count":0},{"state":"ERROR","count":0},{"state":"FAILURE","count":0},{"state":"PENDING","count":2},{"state":"SUCCESS","count":0}]}}}}
                      ]
                    }
                  }
                ]
              },
              "b1": {
                "nodes": [
                  {
                    "number": 59588,
                    "url": "https://github.com/rails/rails/pull/59588",
                    "state": "OPEN",
                    "isDraft": false,
                    "reviewDecision": null,
                    "mergedAt": null,
                    "isCrossRepository": true,
                    "commits": {
                      "nodes": [
                        {"commit":{"statusCheckRollup":{"state":"SUCCESS","contexts":{"totalCount":4,"checkRunCountsByState":[{"state":"ACTION_REQUIRED","count":0},{"state":"CANCELLED","count":0},{"state":"COMPLETED","count":0},{"state":"FAILURE","count":0},{"state":"IN_PROGRESS","count":0},{"state":"NEUTRAL","count":0},{"state":"PENDING","count":0},{"state":"QUEUED","count":0},{"state":"SKIPPED","count":0},{"state":"STALE","count":0},{"state":"STARTUP_FAILURE","count":0},{"state":"SUCCESS","count":2},{"state":"TIMED_OUT","count":0},{"state":"WAITING","count":0}],"statusContextCountsByState":[{"state":"EXPECTED","count":0},{"state":"ERROR","count":0},{"state":"FAILURE","count":0},{"state":"PENDING","count":0},{"state":"SUCCESS","count":2}]}}}}
                      ]
                    }
                  }
                ]
              },
              "b2": {
                "nodes": [
                  {
                    "number": 59587,
                    "url": "https://github.com/rails/rails/pull/59587",
                    "state": "OPEN",
                    "isDraft": true,
                    "reviewDecision": null,
                    "mergedAt": null,
                    "isCrossRepository": true,
                    "commits": {
                      "nodes": [
                        {"commit":{"statusCheckRollup":{"state":"SUCCESS","contexts":{"totalCount":4,"checkRunCountsByState":[{"state":"ACTION_REQUIRED","count":0},{"state":"CANCELLED","count":0},{"state":"COMPLETED","count":0},{"state":"FAILURE","count":0},{"state":"IN_PROGRESS","count":0},{"state":"NEUTRAL","count":0},{"state":"PENDING","count":0},{"state":"QUEUED","count":0},{"state":"SKIPPED","count":0},{"state":"STALE","count":0},{"state":"STARTUP_FAILURE","count":0},{"state":"SUCCESS","count":2},{"state":"TIMED_OUT","count":0},{"state":"WAITING","count":0}],"statusContextCountsByState":[{"state":"EXPECTED","count":0},{"state":"ERROR","count":0},{"state":"FAILURE","count":0},{"state":"PENDING","count":0},{"state":"SUCCESS","count":2}]}}}}
                      ]
                    }
                  }
                ]
              },
              "b3": {
                "nodes": []
              }
            }
          }
        }
        """
}
